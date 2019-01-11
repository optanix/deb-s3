require 'tempfile'
require 'zlib'
require 'deb/s3/utils'
require 'deb/s3/package'

class Deb::S3::Manifest
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :component
  attr_accessor :cache_control
  attr_accessor :architecture
  attr_accessor :fail_if_exists
  attr_accessor :skip_package_upload
  attr_accessor :logger

  attr_accessor :files

  attr_reader :packages
  attr_reader :packages_to_be_upload

  def initialize(logger = nil, logger_level: Logger::INFO)
    @logger = logger.nil? ? Optx::Logger.new(STDOUT, level: logger_level) : logger
    @packages = []
    @packages_to_be_upload = []
    @component = nil
    @architecture = nil
    @files = {}
    @cache_control = ''
    @fail_if_exists = false
    @skip_package_upload = false
    @logger = Optx::Logger.new(STDOUT)
  end

  class << self

    # @param
    def retrieve(codename, component, architecture, cache_control, fail_if_exists, skip_package_upload = false)
      m = if s = Deb::S3::Utils.s3_read("dists/#{codename}/#{component}/binary-#{architecture}/Packages")
            parse_packages(s)
          else
            new
          end

      m.codename = codename
      m.component = component
      m.architecture = architecture
      m.cache_control = cache_control
      m.fail_if_exists = fail_if_exists
      m.skip_package_upload = skip_package_upload
      m
    end

    # @param str [String]
    def parse_packages(str)
      m = new
      str.split("\n\n").each do |s|
        next if s.chomp.empty? || s.empty?

        begin
          m.packages << Deb::S3::Package.parse_string(s)
        rescue StandardError => e
          logger.error e
        end
      end
      m
    end
  end

  def add(pkg, preserve_versions, needs_uploading = true)
    if fail_if_exists
      packages.each do |p|
        next unless p.name == pkg.name && \
                    p.full_version == pkg.full_version && \
                    File.basename(p.url_filename(@codename)) != \
                    File.basename(pkg.url_filename(@codename))

        raise AlreadyExistsError,
              "package #{pkg.name}_#{pkg.full_version} already exists " \
              "with different filename (#{p.url_filename(@codename)})"
      end
    end
    if preserve_versions
      packages.delete_if {|p| p.name == pkg.name && p.full_version == pkg.full_version}
    else
      packages.delete_if {|p| p.name == pkg.name}
    end
    packages << pkg
    packages_to_be_upload << pkg if needs_uploading
    pkg
  end

  def delete_package(pkg, versions = nil)
    deleted = []
    new_packages = @packages.select do |p|
      # Include packages we didn't name
      if p.name != pkg
        p
        # Also include the packages not matching a specified version
      elsif !versions.nil? && (p.name == pkg) && !versions.include?(p.version) && !versions.include?("#{p.version}-#{p.iteration}") && !versions.include?(p.full_version)
        p
      end
    end
    deleted = @packages - new_packages
    @packages = new_packages
    deleted
  end

  def generate
    @packages.collect {|pkg| pkg.generate(@codename)}.join("\n")
  end

  def write_to_s3
    manifest = generate

    unless skip_package_upload
      # store any packages that need to be stored
      @packages_to_be_upload.each do |pkg|
        yield pkg.url_filename(@codename) if block_given?
        s3_store(pkg.filename, pkg.url_filename(@codename), 'application/x-debian-package', cache_control, fail_if_exists)
      end
    end

    # generate the Packages file
    if block_given?
      write_packages_files(manifest) { |f| yield f }
    else
      write_packages_files(manifest)
    end

    nil
  end

  # @return [Hash<Symbol, Object>]
  def to_hash
    {
        packages: packages,
        packages_to_be_upload: packages_to_be_upload,
        component: component,
        architecture: architecture,
        files: files,
        cache_control: cache_control,
        fail_if_exists: fail_if_exists,
        skip_package_upload: skip_package_upload
    }
  end

  # @return [Hash<Symbol, Object>]
  def as_json(*)
    to_hash
  end

  def to_json(*args)
    as_json.to_json(*args)
  end

  private

  def write_packages_files(manifest)
    pkgs_temp = Tempfile.new('Packages')
    pkgs_temp.write manifest
    pkgs_temp.close
    if block_given?
      upload_file(pkgs_temp, 'Packages','text/plain; charset=utf-8') { |f| yield f }
    else
      upload_file(pkgs_temp, 'Packages','text/plain; charset=utf-8')
    end
    pkgs_temp.unlink

    # generate the Packages.gz file
    gztemp = Tempfile.new('Packages.gz')
    gztemp.close
    Zlib::GzipWriter.open(gztemp.path) {|gz| gz.write manifest}
    if block_given?
      upload_file(gztemp, 'Packages.gz','application/x-gzip') { |f| yield f }
    else
      upload_file(gztemp, 'Packages.gz','application/x-gzip')
    end
    gztemp.unlink
  end

  # @param file [Tempfile]
  # @param content_type [String]
  def upload_file(file, name, content_type)
    f = "dists/#{@codename}/#{@component}/binary-#{@architecture}/#{name}"
    yield f if block_given?
    digest = file_digest(file.path)
    @files["#{@component}/binary-#{@architecture}/#{name}"] = digest
    s3_store(file.path, f, content_type, cache_control)

    digest.each do |dig, val|
      next if dig == :size
      hash_name = (dig == :md5) ? "#{dig.to_s.upcase}Sum" : dig.to_s.upcase
      hf = "dists/#{@codename}/#{@component}/binary-#{@architecture}/by-hash/#{hash_name}/#{val}"
      s3_store(file.path, hf, content_type, cache_control)
    end
  end
end
