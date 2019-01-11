require 'aws-sdk'
require 'thor'
require 'deb/s3'
require 'deb/s3/manifest'
require 'deb/s3/release'
require 'nokogiri'
require 'open-uri'
require 'digest'

require 'optx/logger'

module Deb
  module S3
    class Mirror
      attr_accessor :target_repo
      attr_writer :prefix
      attr_accessor :logger
      attr_accessor :temp_dir
      attr_reader :repo_data
      attr_reader :target_host

      # @param target_repo [String]
      # @param prefix [String]
      # @param temp_dir [String]
      # @param logger [Logger]
      # @param logger_level [Logger::Severity]
      def initialize(target_repo, prefix = nil, temp_dir = nil, logger: nil, logger_level: Logger::INFO)
        @target_repo = target_repo.gsub(%r{(^/|/$)}, '')
        @target_host = URI.parse(self.target_repo).host
        @prefix = prefix.gsub(%r{(^/|/$)}, '') unless prefix.nil?
        @temp_dir = temp_dir
        @logger = logger.nil? ? Optx::Logger.new(STDOUT, level: logger_level) : logger
        @repo_data = {}
      end

      # Will download the repo packages into a temp directory
      def cache_repo
        self.temp_dir = Dir.mktmpdir if temp_dir.nil? || !Dir.exist?(temp_dir)

        logger.error("#{target_host}][temp dir: #{temp_dir} does not exist") unless Dir.exist?(temp_dir)

        logger.debug("#{target_host}][using temp dir: #{temp_dir}")

        _cache_repo(temp_dir)
      end

      # @return [Hash<Symbol, Object>]
      def crawl_repo
        logger.info("#{target_host}][starting to crawl")
        @repo_data = {
            target: target_repo,
            prefix: prefix,
            codenames: [],
            components: [],
            architectures: [],
            data: {}
        }

        retrieve_codenames.each do |codename|
          repo_data[:data][codename] = _process_codename(codename)
        end

        _parse_data_hash(repo_data[:data])
        repo_data
      end

      # @return [Array<String>]
      def retrieve_codenames
        logger.info("#{target_host}][retrieving codenames")

        codenames = []
        uri = URI.parse("#{target_repo}/#{prefix}/dists/")
        logger.debug("#{target_host}][trying to determine codenames from #{uri}")

        begin
          doc = Nokogiri::HTML(open(uri))
          doc.search('a').each do |link|
            next if link.content =~ /^\.\./

            codenames << link.content.gsub(%r{/}, '')
          end
        rescue StandardError => e
          logger.error("#{target_host}][unable to retrieve #{uri}")
          logger.error(e)
        end
        logger.debug("#{target_host}][located #{codenames.length} codenames")

        codenames
      end

      # @param codename [String]
      # @return [Array<String>]
      def retrieve_components(codename)
        components = []
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}/")
        logger.debug("#{target_host}][trying to determine components from #{uri}")

        begin
          doc = Nokogiri::HTML(open(uri))
          doc.search('a').each do |link|
            next if link.content =~ /^\.\./
            next if link.content !~ %r{/$}
            next if link.content =~ %r{^pool/$}

            components << link.content.gsub(%r{/}, '')
          end
        rescue StandardError => e
          logger.error(e)
        end
        logger.debug("#{target_host}][located #{components.length} components")

        components
      end

      # @param codename [String]
      # @param component [String]
      # @return [Array<String>]
      def retrieve_architecture(codename, component)
        architectures = []
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}/#{component}/")
        logger.debug("#{target_host}][trying to determine architectures from #{uri}")

        begin
          doc = Nokogiri::HTML(open(uri))
          doc.search('a').each do |link|
            next if link.content =~ /^\.\./
            next if link.content !~ /^binary-/

            architectures << link.content.gsub(/binary-/, '').gsub(%r{/}, '')
          end
        rescue StandardError => e
          logger.error(e)
        end
        logger.debug("#{target_host}][located #{architectures.length} architectures")

        architectures
      end

      # @param codename [String]
      # @return [Deb::S3:Release]
      def retrieve_release(codename)
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}/Release")
        logger.debug("#{target_host}][fetching #{uri}")
        release_raw = Net::HTTP.get(uri)
        release = Deb::S3::Release.parse_release(release_raw)
        release.codename = codename

        logger.debug("#{target_host}][located #{release.components.length} components")
        release
      rescue StandardError => e
        logger.error(e)
        Deb::S3::Release.new
      end

      # @param codename [String]
      # @param component [String]
      # @param architecture [String]
      # @return [Deb::S3::Manifest]
      def retrieve_manifest(codename, component, architecture)
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}/#{component}/binary-#{architecture}/Packages")
        logger.debug("#{target_host}][fetching #{uri}")

        manifest_raw = Net::HTTP.get(uri)

        manifest = Deb::S3::Manifest.parse_packages(manifest_raw)

        logger.debug("#{target_host}][located #{manifest.packages.length} packages")
        # manifest.packages.each do |package|
        #   puts "#{package.name} => #{package.version} => #{package.iteration}"
        # end

        manifest
      rescue StandardError => e
        logger.error(e)
        Deb::S3::Manifest.new
      end

      # @return [String] the repository url prefix or '' if nil
      def prefix
        if @prefix.nil?
          ''
        else
          @prefix
        end
      end

      private

      # @param codename [String]
      # @return [Hash<Symbol, Object>]
      def _process_codename(codename)
        logger.debug("#{target_host}][processing #{codename}")
        data = {
            name: codename,
            type: :codename,
            release: retrieve_release(codename),
            data: {}
        }

        retrieve_components(codename).each do |component|
          data[:data][component] = _process_component(codename, component)
        end

        data
      end

      # @param codename [String]
      # @param component [String]
      # @return [Hash<Symbol, Object>]
      def _process_component(codename, component)
        data = {
            name: component,
            type: :component,
            data: {}
        }

        retrieve_architecture(codename, component).each do |architecture|
          data[:data][architecture] = {
              name: architecture,
              type: :architecture,
              manifest: retrieve_manifest(codename, component, architecture),
              data: {}
          }
        end

        data
      end

      # Will populate the @repo_data sub lists with all the possible values
      # @param data [Hash<Symbol, Object>]
      def _parse_data_hash(data)
        data.each_value do |hash|
          case hash[:type]
          when :codename
            repo_data[:codenames] << hash[:name] unless repo_data[:codenames].include? hash[:name]
          when :component
            repo_data[:components] << hash[:name] unless repo_data[:components].include? hash[:name]
          when :architecture
            repo_data[:architectures] << hash[:name] unless repo_data[:architectures].include? hash[:name]
          end

          _parse_data_hash(hash[:data]) if hash.key? :data
        end
      end

      # Will create sub directories and download the debian files using a url safe name
      def _cache_repo(dir)
        logger.info("#{target_host}][starting to cache repo")

        Dir.chdir(dir) do
          Dir.mkdir(target_host) unless Dir.exist?(target_host)
          Dir.chdir(target_host) do
            repo_data[:data].each_value do |codename_data|
              codename_data[:data].each_value do |component_data|
                component_dir = File.join(dir, target_host, component_data[:name])
                Dir.mkdir(component_dir) unless Dir.exist?(component_dir)
                Dir.chdir(component_dir) do
                  component_data[:data].each_value do |architecture_data|
                    architecture_dir = File.join(component_dir, architecture_data[:name])
                    Dir.mkdir(architecture_dir) unless Dir.exist?(architecture_dir)
                    Dir.chdir(architecture_dir) do
                      # Update manifest
                      architecture_data[:manifest].component = component_data[:name]
                      architecture_data[:manifest].architecture = architecture_data[:name]

                      # Download each package
                      architecture_data[:manifest].packages.each do |package|
                        _download_package(architecture_dir, package)
                        # Set the url path to nil so it can be uploaded to a correct location
                        package.url_filename = nil
                      end
                    end
                  end
                end
              end
            end
          end
        end

        logger.info("#{target_host}][finished caching repo")
      end

      # @param dir [String]
      # @param package [Deb::S3::Package]
      def _download_package(dir, package)
        uri = URI.parse("#{target_repo}/#{prefix}/#{package.url_filename}")
        logger.info("#{target_host}][downloading #{uri}")
        file_name = File.join(dir, package.safe_name)
        package.filename = File.absolute_path(file_name)

        if File.exist?(package.safe_name)
          logger.warn "#{target_host}][file already exists! #{package.safe_name} => #{uri}"
          package.check_digest
          return
        end

        open(file_name, 'wb') do |file|
          file << open(uri).read
        end

        logger.info("#{target_host}][successfully downloaded #{package.url_filename} to #{package.filename}")
        package.check_digest
      rescue StandardError => e
        logger.error(e)
      end

    end
  end
end
