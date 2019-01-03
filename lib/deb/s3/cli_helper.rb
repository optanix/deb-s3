require 'optx/logger'

module Deb
  module S3
    module CLIHelper
      protected


      def release_lock!
        if options[:lock] && @lock_acquired
          Deb::S3::Lock.unlock(options[:codename], component, options[:arch], options[:cache_control])
          log('Lock released.')
        end
      end

      def init_lock!
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
      end

      def component
        return @component if @component

        @component = if (section = options[:section])
                       warn('===> WARNING: The --section/-s argument is ' \
                        'deprecated, please use --component/-m.')
                       section
                     else
                       options[:component]
                     end
      end

      def logger
        @logger ||= Optx::Logger.new(STDOUT, level: Logger::DEBUG)
      end

      def puts(*args)
        logger.debug(*args) unless options[:quiet]
      end

      def log(message)
        logger.info(message) unless options[:quiet]
      end

      def sublog(message)
        logger.info "   -- #{message}" unless options[:quiet]
      end

      def error(message)
        logger.error "!! #{message}" unless options[:quiet]
        exit 1
      end

      def provider
        access_key_id = options[:access_key_id]
        secret_access_key = options[:secret_access_key]
        session_token = options[:session_token]

        if access_key_id.nil? ^ secret_access_key.nil?
          error('If you specify one of --access-key-id or --secret-access-key, you must specify the other.')
        end
        static_credentials = {}
        static_credentials[:access_key_id] = access_key_id if access_key_id
        static_credentials[:secret_access_key] = secret_access_key if secret_access_key
        static_credentials[:session_token] = session_token if session_token

        static_credentials
      end

      def configure_s3_client
        error("No value provided for required options '--bucket'") unless options[:bucket]

        settings = {
          region: options[:s3_region],
          http_proxy: options[:proxy_uri],
          force_path_style: options[:force_path_style]
        }
        settings[:endpoint] = options[:endpoint] if options[:endpoint]
        settings.merge!(provider)

        Deb::S3::Utils.s3 = Aws::S3::Client.new(settings)
        Deb::S3::Utils.bucket = options[:bucket]
        Deb::S3::Utils.signing_key = options[:sign]
        Deb::S3::Utils.gpg_options = options[:gpg_options]
        Deb::S3::Utils.prefix = options[:prefix]
        Deb::S3::Utils.encryption = options[:encryption]

        # make sure we have a valid visibility setting
        Deb::S3::Utils.access_policy =
          case options[:visibility]
          when 'public'
            'public-read'
          when 'private'
            'private'
          when 'authenticated'
            'authenticated-read'
          when 'bucket_owner'
            'bucket-owner-full-control'
          else
            error('Invalid visibility setting given. Can be public, private, authenticated, or bucket_owner.')
          end
      end
    end
  end
end
