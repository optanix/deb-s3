require 'digest/sha1'
require 'digest/sha2'
require 'digest/md5'
require 'socket'
require 'tmpdir'
require 'uri'
require 'English'
require 'deb/s3/utils'

class Deb::S3::Package
  include Deb::S3::Utils

  attr_accessor :name
  attr_accessor :version
  attr_accessor :epoch
  attr_accessor :iteration
  attr_accessor :maintainer
  attr_accessor :vendor
  attr_accessor :url
  attr_accessor :category
  attr_accessor :license
  attr_accessor :architecture
  attr_accessor :description
  attr_accessor :dependencies
  attr_accessor :logger

  # Any other attributes specific to this package.
  # This is where you'd put rpm, deb, or other specific attributes.
  attr_accessor :attributes

  # hashes
  attr_accessor :sha1
  attr_accessor :sha256
  attr_accessor :sha512
  attr_accessor :md5
  attr_accessor :size

  attr_reader :filename
  attr_writer :url_filename

  class << self
    include Deb::S3::Utils

    def parse_file(package)
      p = new
      p.extract_info(extract_control(package))
      p.check_digest
      p.filename = package
      p
    end

    def parse_string(s)
      p = new
      p.extract_info(s)
      p
    end

    def extract_control(package)
      if system('which dpkg > /dev/null 2>&1')
        `dpkg -f #{package}`
      else
        # ar fails to find the control.tar.gz tarball within the .deb
        # on Mac OS. Try using ar to list the control file, if found,
        # use ar to extract, otherwise attempt with tar which works on OS X.
        extract_control_tarball_cmd = "ar p #{package} control.tar.gz"

        begin
          safesystem("ar t #{package} control.tar.gz &> /dev/null")
        rescue SafeSystemError
          warn 'Failed to find control data in .deb with ar, trying tar.'
          extract_control_tarball_cmd = "tar zxf #{package} --to-stdout control.tar.gz"
        end

        Dir.mktmpdir do |path|
          safesystem("#{extract_control_tarball_cmd} | tar -zxf - -C #{path}")
          File.read(File.join(path, 'control'), encoding: 'UTF-8')
        end
      end
    end
  end

  def initialize(logger = nil, logger_level: Logger::INFO)
    @logger = logger.nil? ? Optx::Logger.new(STDOUT, level: logger_level) : logger

    @attributes = {}

    # Reference
    # http://www.debian.org/doc/manuals/maint-guide/first.en.html
    # http://wiki.debian.org/DeveloperConfiguration
    # https://github.com/jordansissel/fpm/issues/37
    @maintainer = if ENV.include?('DEBEMAIL') && ENV.include?('DEBFULLNAME')
                    # Use DEBEMAIL and DEBFULLNAME as the default maintainer if available.
                    "#{ENV['DEBFULLNAME']} <#{ENV['DEBEMAIL']}>"
                  else
                    # TODO(sissel): Maybe support using 'git config' for a default as well?
                    # git config --get user.name, etc can be useful.
                    #
                    # Otherwise default to user@currenthost
                    "<#{ENV['USER']}@#{Socket.gethostname}>"
                  end

    @name = nil
    @architecture = 'native'
    @description = 'no description given'
    @version = nil
    @epoch = nil
    @iteration = nil
    @url = nil
    @category = 'default'
    @license = 'unknown'
    @vendor = 'none'
    @sha1 = nil
    @sha256 = nil
    @md5 = nil
    @size = nil
    @filename = nil

    @dependencies = []
  end

  def full_version
    return nil if [epoch, version, iteration].all?(&:nil?)

    [[epoch, version].compact.join(':'), iteration].compact.join('-')
  end

  def filename=(f)
    @filename = f
    @filename
  end

  def safe_name
    "#{name}_#{version}-#{iteration}_#{architecture}.deb".gsub(/[^a-zA-Z0-9_\-\.]/, '-')
  end

  def safe_url_path(codename = nil)
    if codename.nil?
      "pool/#{name[0]}/#{name[0..1]}/#{safe_name}"
    else
      "pool/#{codename}/#{name[0]}/#{name[0..1]}/#{safe_name}"
    end
  end

  def url_filename(codename = nil)
    @url_filename ||= safe_url_path(codename)
  end

  def url_filename_encoded(codename)
    @url_filename ||= safe_url_path(codename)
  end

  def generate(codename = nil)
    template('package.erb').result(binding)
  end

  # from fpm
  def parse_depends(data)
    return [] if data.nil? || data.empty?

    # parse dependencies. Debian dependencies come in one of two forms:
    # * name
    # * name (op version)
    # They are all on one line, separated by ", "

    dep_re = /^([^ ]+)(?: \(([>=<]+) ([^)]+)\))?$/
    data.split(/, */).collect do |dep|
      m = dep_re.match(dep)
      if m
        name, op, version = m.captures
        # this is the proper form of dependency
        if op && version && op != '' && version != ''
          "#{name} (#{op} #{version})".strip
        else
          name.strip
        end
      else
        # Assume normal form dependency, "name op version".
        dep
      end
    end
  end

  # def parse_depends

  # from fpm
  def fix_dependency(dep)
    # Deb dependencies are: NAME (OP VERSION), like "zsh (> 3.0)"
    # Convert anything that looks like 'NAME OP VERSION' to this format.
    if /[\(,\|]/.match?(dep)
      # Don't "fix" ones that could appear well formed already.
    else
      # Convert ones that appear to be 'name op version'
      name, op, version = dep.split(/ +/)
      unless version.nil?
        # Convert strings 'foo >= bar' to 'foo (>= bar)'
        dep = "#{name} (#{debianize_op(op)} #{version})"
      end
    end

    name_re = /^[^ \(]+/
    name = dep[name_re]
    dep = dep.gsub(name_re, &:downcase) if /[A-Z]/.match?(name)

    dep = dep.tr('_', '-') if dep.include?('_')

    # Convert gem ~> X.Y.Z to '>= X.Y.Z' and << X.Y+1.0
    if /\(~>/.match?(dep)
      name, version = dep.gsub(/[()~>]/, '').split(/ +/)[0..1]
      nextversion = version.split('.').collect(&:to_i)
      l = nextversion.length
      nextversion[l - 2] += 1
      nextversion[l - 1] = 0
      nextversion = nextversion.join('.')
      return ["#{name} (>= #{version})", "#{name} (<< #{nextversion})"]
    elsif (m = dep.match(/(\S+)\s+\(!= (.+)\)/))
      # Append this to conflicts
      self.conflicts += [dep.gsub(/!=/, '=')]
      return []
    elsif (m = dep.match(/(\S+)\s+\(= (.+)\)/)) &&
          attributes[:deb_ignore_iteration_in_dependencies?]
      # Convert 'foo (= x)' to 'foo (>= x)' and 'foo (<< x+1)'
      # but only when flag --ignore-iteration-in-dependencies is passed.
      name, version = m[1..2]
      nextversion = version.split('.').collect(&:to_i)
      nextversion[-1] += 1
      nextversion = nextversion.join('.')
      return ["#{name} (>= #{version})", "#{name} (<< #{nextversion})"]
    else
      # otherwise the dep is probably fine
      return dep.rstrip
    end
  end

  # def fix_dependency

  # from fpm
  def extract_info(control)
    fields = parse_control(control)

    # Parse 'epoch:version-iteration' in the version string
    full_version = fields.delete('Version')
    raise "Unsupported version string '#{full_version}'" if full_version !~ /^(?:([0-9]+):)?(.+?)(?:-(.*))?$/

    self.epoch, self.version, self.iteration = $LAST_MATCH_INFO.captures

    self.architecture = fields.delete('Architecture')
    self.category = fields.delete('Section')
    self.license = fields.delete('License') || license
    self.maintainer = fields.delete('Maintainer')
    self.name = fields.delete('Package')
    self.url = fields.delete('Homepage')
    self.vendor = fields.delete('Vendor') || vendor
    attributes[:deb_priority] = fields.delete('Priority')
    attributes[:deb_origin] = fields.delete('Origin')
    attributes[:deb_installed_size] = fields.delete('Installed-Size')

    # Packages manifest fields
    filename = fields.delete('Filename')
    self.url_filename = filename && URI.decode(filename)
    self.sha1 = fields.delete('SHA1')
    self.sha256 = fields.delete('SHA256')
    self.sha256 = fields.delete('SHA512')
    self.md5 = fields.delete('MD5sum')
    self.size = fields.delete('Size')
    self.description = fields.delete('Description')

    # self.config_files = config_files

    self.dependencies += Array(parse_depends(fields.delete('Depends')))

    attributes[:deb_recommends] = fields.delete('Recommends')
    attributes[:deb_suggests] = fields.delete('Suggests')
    attributes[:deb_enhances] = fields.delete('Enhances')
    attributes[:deb_pre_depends] = fields.delete('Pre-Depends')

    attributes[:deb_breaks] = fields.delete('Breaks')
    attributes[:deb_conflicts] = fields.delete('Conflicts')
    attributes[:deb_provides] = fields.delete('Provides')
    attributes[:deb_replaces] = fields.delete('Replaces')

    attributes[:deb_field] = Hash[fields.map do |k, v|
      [k.sub(/\AX[BCS]{0,3}-/, ''), v]
    end]
  end

  # Will compare and update the package digest information. If a miss match occurs it will exit
  def check_digest
    data = file_digest(self.filename)
    self.size = data[:size]

    logger.info("#{self.safe_name}][calculated digests][SHA1: #{data[:sha1]}][SHA256: #{data[:sha256]}][SHA512: #{data[:sha512]}][MD5: #{data[:md5]}")

    if self.md5.nil?
      self.md5 = data[:md5]
    elsif self.md5 != data[:md5]
      logger.error("#{self.safe_name}][calculated digests of MD5 does not match!][calculated: #{data[:md5]} provided: #{self.md5}")
      self.md5 = data[:md5]
    end

    if self.sha1.nil?
      self.sha1 = data[:sha1]
    elsif self.sha1 != data[:sha1]
      logger.error("#{self.safe_name}][calculated digests of SHA1 does not match!][calculated: #{data[:sha1]} provided: #{self.sha1}")
      self.sha1 = data[:sha1]
    end

    if self.sha256.nil?
      self.sha256 = data[:sha256]
    elsif self.sha256 != data[:sha256]
      logger.error("#{self.safe_name}][calculated digests of SHA256 does not match!][calculated: #{data[:sha256]} provided: #{self.sha256}")
      self.sha256 = data[:sha256]
    end

    if self.sha512.nil?
      self.sha512 = data[:sha512]
    elsif self.sha512 != data[:sha512]
      logger.error("#{self.safe_name}][calculated digests of SHA512 does not match!][calculated: #{data[:sha512]} provided: #{self.sha512}")
      self.sha512 = data[:sha512]
    end
  end

  def parse_control(control)
    field = nil
    value = ''

    {}.tap do |fields|
      control.each_line do |line|
        if line =~ /^(\s+)(\S.*)$/
          indent = Regexp.last_match(1)
          rest = Regexp.last_match(2)
          # Continuation
          if indent.size == 1 && rest == '.'
            value << "\n"
            rest = ''
          elsif !value.empty?
            value << "\n"
          end
          value << rest
        elsif line =~ /^([-\w]+):(.*)$/
          fields[field] = value if field
          field = Regexp.last_match(1)
          value = Regexp.last_match(2).strip
        end
      end
      fields[field] = value if field
    end
  end

  # @return [Hash<Symbol, Object>]
  def to_hash
    {
      name: name,
      maintainer: maintainer,
      architecture: architecture,
      description: description,
      version: version,
      epoch: epoch,
      iteration: iteration,
      url: url,
      category: category,
      license: license,
      vendor: vendor,
      sha1: sha1,
      sha256: sha256,
      md5: md5,
      size: size,
      filename: filename,
      url_filename: url_filename,
      dependencies: dependencies
    }
  end

  # @return [Hash<Symbol, Object>]
  def as_json(*)
    to_hash
  end

  def to_json(*args)
    as_json.to_json(*args)
  end
end
