require 'aws-sdk'
require 'thor'

# HACK: aws requires this!
require 'json'

require 'deb/s3'
require 'deb/s3/utils'
require 'deb/s3/manifest'
require 'deb/s3/package'
require 'deb/s3/release'
require 'deb/s3/lock'
require 'deb/s3/mirror'
require 'deb/s3/cli_helper'

class Deb::S3::CLIMirror < Thor
  include Deb::S3::CLIHelper

  class_option :bucket,
               type: :string,
               aliases: '-b',
               desc: 'The name of the S3 bucket to upload to.'

  class_option :prefix,
               type: :string,
               desc: 'The path prefix to use when storing on S3.'

  class_option :origin,
               type: :string,
               aliases: '-o',
               desc: 'The origin to use in the repository Release file.'

  class_option :suite,
               type: :string,
               desc: 'The suite to use in the repository Release file.'

  class_option :codename,
               default: 'stable',
               type: :string,
               aliases: '-c',
               desc: 'The codename of the APT repository.'

  class_option :component,
               default: 'main',
               type: :string,
               aliases: '-m',
               desc: 'The component of the APT repository.'

  class_option :section,
               type: :string,
               aliases: '-s',
               hide: true

  class_option :access_key_id,
               type: :string,
               desc: 'The access key for connecting to S3.'

  class_option :secret_access_key,
               type: :string,
               desc: 'The secret key for connecting to S3.'

  class_option :session_token,
               type: :string,
               desc: 'The (optional) session token for connecting to S3.'

  class_option :endpoint,
               type: :string,
               desc: 'The URL endpoint to the S3 API.'

  class_option :s3_region,
               type: :string,
               desc: 'The region for connecting to S3.',
               default: ENV['AWS_DEFAULT_REGION'] || 'us-east-1'

  class_option :force_path_style,
               default: false,
               type: :boolean,
               desc: 'Use S3 path style instead of subdomains.'

  class_option :proxy_uri,
               type: :string,
               desc: 'The URI of the proxy to send service requests through.'

  class_option :visibility,
               default: 'public',
               type: :string,
               aliases: '-v',
               desc: 'The access policy for the uploaded files. ' \
                            'Can be public, private, or authenticated.'

  class_option :sign,
               type: :string,
               desc: 'GPG Sign the Release file when uploading a package, ' \
                            'or when verifying it after removing a package. ' \
                            'Use --sign with your GPG key ID to use a specific key (--sign=6643C242C18FE05B).'

  class_option :gpg_options,
               default: '',
               type: :string,
               desc: 'Additional command line options to pass to GPG when signing.'

  class_option :encryption,
               default: false,
               type: :boolean,
               aliases: '-e',
               desc: 'Use S3 server side encryption.'

  class_option :quiet,
               type: :boolean,
               aliases: '-q',
               desc: "Doesn't output information, just returns status appropriately."

  class_option :cache_control,
               type: :string,
               aliases: '-C',
               desc: 'Add cache-control headers to S3 objects.'

  desc 'mirror url',
       'Mirrors the provided repo'

  option :arch,
         type: :string,
         aliases: '-a',
         desc: 'The architecture of the package in the APT repository.'

  option :preserve_versions,
         default: true,
         type: :boolean,
         aliases: '-p',
         desc: 'Whether to preserve other versions of a package ' \
                      'in the repository when uploading one.'

  option :lock,
         default: false,
         type: :boolean,
         aliases: '-l',
         desc: 'Whether to check for an existing lock on the repository ' \
                      'to prevent simultaneous updates '

  option :fail_if_exists,
         default: false,
         type: :boolean,
         desc: 'Whether to overwrite any existing package that has the same ' \
                      'filename in the pool or the same name and version in the manifest but ' \
                       'different contents.'

  option :skip_package_upload,
         default: false,
         type: :boolean,
         desc: 'Whether to skip all package uploads.' \
                      'This is useful when hosting .deb files outside of the bucket.'

  option :cache_dir,
         default: '',
         type: :string,
         desc: 'The directory to cache the repo files'

  def mirror(url)
    # configure AWS::S3
    configure_s3_client

    begin
      if options[:lock]
        log('Checking for existing lock file')
        if Deb::S3::Lock.locked?(options[:codename], component, options[:arch], options[:cache_control])
          lock = Deb::S3::Lock.current(options[:codename], component, options[:arch], options[:cache_control])
          log("Repository is locked by another user: #{lock.user} at host #{lock.host}")
          log('Attempting to obtain a lock')
          Deb::S3::Lock.wait_for_lock(options[:codename], component, options[:arch], options[:cache_control])
        end
        log('Locking repository for updates')
        Deb::S3::Lock.lock(options[:codename], component, options[:arch], options[:cache_control])
        @lock_acquired = true
      end

      # retrieve the existing manifests
      log('Retrieving existing manifests')
      release = Deb::S3::Release.retrieve(options[:codename], options[:origin], options[:suite], options[:cache_control])
      manifests = {}
      release.architectures.each do |arch|
        manifests[arch] = Deb::S3::Manifest.retrieve(
          options[:codename], component, arch,
          options[:cache_control],
          options[:fail_if_exists],
          options[:skip_package_upload]
        )
      end

      uri = URI.parse(url)

      mirror = Deb::S3::Mirror.new("#{uri.scheme}://#{uri.host}", uri.path, options[:cache_dir])
      log('Crawling repo')
      mirror.crawl_repo
      log('Caching repo')
      mirror.cache_repo

      packages_arch_all = []

      if mirror.repo_data[:data].key? options[:codename]
        mirror.repo_data[:data][options[:codename]][:data].each_value do |component_data|
          component_data[:data].each_value do |architecture_data|
            architecture_data[:manifest].packages.each do |pkg|
              arch = architecture_data[:name]

              manifests[arch] = architecture_data[:manifest] unless manifests.key? arch
              # add package in manifests
              begin
                manifests[arch].add(pkg, options[:preserve_versions])
              rescue Deb::S3::Utils::AlreadyExistsError => e
                error("Preparing manifest failed because: #{e}")
              end

              # If arch is all, we must add this package in all arch available
              packages_arch_all << pkg if arch == 'all'
            end
          end
        end
      end

      manifests.each do |arch, manifest|
        manifest.codename = options[:codename]

        next if arch == 'all'

        packages_arch_all.each do |pkg|
          begin
            manifest.add(pkg, options[:preserve_versions], false)
          rescue Deb::S3::Utils::AlreadyExistsError => e
            error("Preparing manifest failed because: #{e}")
          end
        end
      end

      # upload the manifest
      log('Uploading packages and new manifests to S3')
      manifests.each_value do |manifest|
        begin
          manifest.write_to_s3 { |f| sublog("Transferring #{f}") }
        rescue Deb::S3::Utils::AlreadyExistsError => e
          error("Uploading manifest failed because: #{e}")
        end
        release.update_manifest(manifest)
      end
      release.write_to_s3 { |f| sublog("Transferring #{f}") }
    ensure
      if options[:lock] && @lock_acquired
        Deb::S3::Lock.unlock(options[:codename], component, options[:arch], options[:cache_control])
        log('Lock released.')
      end
    end
  end
end
