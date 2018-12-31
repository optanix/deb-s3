# frozen_string_literal: true

require 'aws-sdk'
require 'thor'
require 'deb/s3'
require 'deb/s3/manifest'
require 'deb/s3/release'
require 'nokogiri'
require 'open-uri'

module Deb
  module S3
    class Mirror
      attr_accessor :target_repo
      attr_writer :prefix
      attr_accessor :logger
      attr_accessor :temp_dir
      attr_reader :repo_data

      def initialize(target_repo, prefix = nil, temp_dir = nil)
        self.target_repo = target_repo
        self.prefix = prefix
        self.temp_dir = temp_dir
        self.logger = Logger.new(STDOUT)

        @repo_data = {}
      end

      # @return [Hash<Symbol, Object>]
      def crawl_repo
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
        codenames = []
        uri = URI.parse("#{target_repo}/#{prefix}/dists")
        logger.debug("trying to determine codenames from #{uri}")

        begin
          doc = Nokogiri::HTML(open(uri))
          doc.search('a').each do |link|
            next if link.content =~ /^\.\./

            codenames << link.content.gsub(%r{/}, '')
          end
        rescue StandardError => e
          logger.error(e)
        end
        logger.debug("located #{codenames.length} codenames")

        codenames
      end

      # @param codename [String]
      # @return [Array<String>]
      def retrieve_components(codename)
        components = []
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}")
        logger.debug("trying to determine components from #{uri}")

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
        logger.debug("located #{components.length} components")

        components
      end

      # @param codename [String]
      # @param component [String]
      # @return [Array<String>]
      def retrieve_architecture(codename, component)
        architectures = []
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}/#{component}")
        logger.debug("trying to determine architectures from #{uri}")

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
        logger.debug("located #{architectures.length} architectures")

        architectures
      end

      # @param codename [String]
      # @return [Deb::S3:Release]
      def retrieve_release(codename)
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}/Release")
        logger.debug("Fetching #{uri}")
        release_raw = Net::HTTP.get(uri)
        release = Deb::S3::Release.parse_release(release_raw)
        logger.debug("located #{release.components.length} components")
        release
      end

      # @param codename [String]
      # @param component [String]
      # @param architecture [String]
      # @return [Deb::S3::Manifest]
      def retrieve_manifest(codename, component, architecture)
        uri = URI.parse("#{target_repo}/#{prefix}/dists/#{codename}/#{component}/binary-#{architecture}/Packages")
        logger.debug("Fetching #{uri}")

        manifest_raw = Net::HTTP.get(uri)
        manifest = Deb::S3::Manifest.parse_packages(manifest_raw)

        logger.debug("located #{manifest.packages.length} packages")
        manifest.packages.each do |package|
          puts "#{package.name} => #{package.version} => #{package.iteration}"
        end
        manifest
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
        data = {
          name: codename,
          type: :codename,
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

        retrieve_architecture(codename, component).each do |arch|
          data[:data][arch] = {
            name: arch,
            type: :architecture,
            data: {}
          }
        end

        data
      end

      # Will populate the @repo_data sub lists with all the possible values
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
    end
  end
end
