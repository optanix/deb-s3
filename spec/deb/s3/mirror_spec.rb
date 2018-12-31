# frozen_string_literal: true

require File.expand_path('../../spec_helper', __dir__)
require 'deb/s3/mirror'

describe Deb::S3::Mirror do
  let(:mirror) { Deb::S3::Mirror.new('https://download.docker.com', 'linux/ubuntu') }

  it 'retrieves release for xenial' do
    releases = mirror.retrieve_release('xenial')
    expect(releases).to be_a Deb::S3::Release
  end

  it 'retrieves manifest' do
    manifest = mirror.retrieve_manifest('xenial', 'stable', 'amd64')
    expect(manifest).to be_a Deb::S3::Manifest
  end

  it 'retrieves codenames' do
    expect(mirror.retrieve_codenames.length).to_not be 0
  end

  it 'retrieves components' do
    expect(mirror.retrieve_components('xenial').length).to_not be 0
  end

  it 'retrieves architectures' do
    expect(mirror.retrieve_architecture('xenial', 'stable').length).to_not be 0
  end

  it 'crawls repo' do
    repo_data = mirror.crawl_repo
    expect(repo_data[:codenames].length).to_not be 0
    expect(repo_data[:components].length).to_not be 0
    expect(repo_data[:architectures].length).to_not be 0
  end
end
