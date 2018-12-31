# frozen_string_literal: true

require File.expand_path('../../spec_helper', __dir__)
require 'deb/s3/manifest'

# Enable a setter for packages
class Deb::S3::Manifest
  attr_writer :packages
end

describe Deb::S3::Manifest do
  before do
    @manifest = Deb::S3::Manifest.new
  end

  describe '#add' do
    it 'removes packages which have the same full version' do
      epoch = Time.now.to_i
      @manifest.packages = [create_package(name: 'discourse', epoch: epoch, version: '0.9.8.3', iteration: '1')]
      new_package = create_package name: 'discourse', epoch: epoch, version: '0.9.8.3', iteration: '1'

      @manifest.add(new_package, true)
      expect(@manifest.packages.length).to eq 1
    end

    it 'does not remove packages based only on the version' do
      @manifest.packages = [create_package(name: 'discourse', version: '0.9.8.3', iteration: '1')]
      new_package = create_package name: 'discourse', version: '0.9.8.3', iteration: '2'

      @manifest.add(new_package, true)
      expect(@manifest.packages.length).to eq 2
    end

    it 'removes any package with the same name, independently of the full version, if preserve_versions is false' do
      @manifest.packages = [
        create_package(name: 'discourse', version: '0.9.8.3', iteration: '1'),
        create_package(name: 'discourse'),
        create_package(name: 'discourse', version: '0.9.8.4', iteration: '1', epoch: '2')
      ]
      new_package = create_package name: 'discourse', version: '0.9.8.5'

      @manifest.add(new_package, false)
      expect(@manifest.packages).to eq [new_package]
    end
  end

  describe '#delete_package' do
    it 'removes packages which have the same version as one of the versions specified' do
      epoch = Time.now.to_i
      existing_packages_with_same_version = [
        create_package(name: 'discourse', epoch: epoch, version: '0.9.8.3', iteration: '1'),
        create_package(name: 'discourse', epoch: epoch, version: '0.9.0.0', iteration: '1'),
        create_package(name: 'discourse', epoch: epoch, version: '0.9.0.0', iteration: '2')
      ]
      existing_packages_with_different_version = [
        create_package(name: 'discourse', epoch: epoch, version: '0.9.8.3', iteration: '2')
      ]
      versions_to_delete = ["#{epoch}:0.9.8.3-1", '0.9.0.0']

      @manifest.packages = existing_packages_with_same_version + existing_packages_with_different_version

      @manifest.delete_package('discourse', versions_to_delete)
      expect(@manifest.packages).to eq existing_packages_with_different_version

      # Reset the attribute
      @manifest.instance_variable_set(:@packages, [])
    end
  end
end
