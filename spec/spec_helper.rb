$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'deb/s3'
require 'vcr'
require 'webmock'

def fixture(name)
  File.expand_path("../fixtures/#{name}", __FILE__)
end

def create_package(attributes = {})
  package = Deb::S3::Package.new
  attributes.each do |k, v|
    package.send("#{k}=".to_sym, v)
  end
  package
end

VCR.configure do |config|
  config.cassette_library_dir = 'spec/cassettes'
  config.hook_into :webmock
  config.configure_rspec_metadata!
end

RSpec.configure do |config|
  config.raise_errors_for_deprecations!

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
