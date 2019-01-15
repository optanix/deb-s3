require 'base64'
require 'digest'
require 'erb'
require 'tmpdir'

module Deb::S3::Utils
  module_function

  def s3
    @s3
  end

  def s3=(v)
    @s3 = v
  end

  def bucket
    @bucket
  end

  def bucket=(v)
    @bucket = v
  end

  def access_policy
    @access_policy
  end

  def access_policy=(v)
    @access_policy = v
  end

  def signing_key
    @signing_key
  end

  def signing_key=(v)
    @signing_key = v
  end

  def gpg_options
    @gpg_options
  end

  def gpg_options=(v)
    @gpg_options = v
  end

  def prefix
    @prefix
  end

  def prefix=(v)
    @prefix = v
  end

  def encryption
    @encryption
  end

  def encryption=(v)
    @encryption = v
  end

  class SafeSystemError < RuntimeError;
  end
  class AlreadyExistsError < RuntimeError;
  end

  def safesystem(*args)
    success = system(*args)
    unless success
      raise SafeSystemError, "'system(#{args.inspect})' failed with error code: #{$CHILD_STATUS.exitstatus}"
    end

    success
  end

  def debianize_op(op)
    # Operators in debian packaging are <<, <=, =, >= and >>
    # So any operator like < or > must be replaced
    {:< => '<<', :> => '>>'}[op.to_sym] || op
  end

  def template(path)
    template_file = File.join(File.dirname(__FILE__), 'templates', path)
    template_code = File.read(template_file)
    ERB.new(template_code, nil, '-')
  end

  def s3_path(path)
    File.join(*[Deb::S3::Utils.prefix, path].compact)
  end

  # from fog, Fog::AWS.escape
  def s3_escape(string)
    string.gsub(/([^a-zA-Z0-9_.\-~+]+)/) do
      '%' + Regexp.last_match(1).unpack('H2' * Regexp.last_match(1).bytesize).join('%').upcase
    end
  end

  def s3_exists?(path)
    Deb::S3::Utils.s3.head_object(
        bucket: Deb::S3::Utils.bucket,
        key: s3_path(path)
    )
  rescue Aws::S3::Errors::NotFound
    false
  end

  def s3_read(path)
    Deb::S3::Utils.s3.get_object(
        bucket: Deb::S3::Utils.bucket,
        key: s3_path(path)
    )[:body].read
  rescue Aws::S3::Errors::NoSuchKey
    false
  end

  def s3_store(path, filename = nil, content_type = 'application/octet-stream; charset=binary', cache_control = nil, fail_if_exists = false)
    filename ||= File.basename(path)
    obj = s3_exists?(filename)

    file_md5 = Digest::MD5.file(path)

    # check if the object already exists
    if obj
      return if (file_md5.to_s == obj[:etag].delete('"')) || (file_md5.to_s == obj[:metadata]['md5'])
      logger.error("file #{filename} already exists with different contents")
      raise AlreadyExistsError, "file #{filename} already exists with different contents" if fail_if_exists
    end

    options = {
        bucket: Deb::S3::Utils.bucket,
        key: s3_path(filename),
        acl: Deb::S3::Utils.access_policy,
        content_type: content_type,
        metadata: {'md5' => file_md5.to_s}
    }
    options[:cache_control] = cache_control unless cache_control.nil?

    # specify if encryption is required
    options[:server_side_encryption] = 'AES256' if Deb::S3::Utils.encryption

    # upload the file
    File.open(path) do |f|
      options[:body] = f
      Deb::S3::Utils.s3.put_object(options)
    end
  end

  def s3_remove(path)
    if s3_exists?(path)
      Deb::S3::Utils.s3.delete_object(
          bucket: Deb::S3::Utils.bucket,
          key: s3_path(path)
      )
    end
  end

  # @param path [String]
  # @return [Hash<Symbol, String>]
  def file_digest(path)
    {
        size: File.size(path),
        sha1: Digest::SHA1.file(path).hexdigest,
        sha256: Digest::SHA256.file(path).hexdigest,
        sha512: Digest::SHA512.file(path).hexdigest,
        md5: Digest::MD5.file(path).hexdigest
    }
  end

  def logger
    @logger ||= Optx::Logger.new(STDOUT, level: Logger::DEBUG)
  end
end
