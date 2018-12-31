# frozen_string_literal: true

require File.expand_path('../../spec_helper', __dir__)
require 'deb/s3/package'

EXPECTED_DESCRIPTION = "A platform for community discussion. Free, open, simple.\nThe description can have a continuation line.\n\nAnd blank lines.\n\nIf it wants to."

describe Deb::S3::Package do
  describe '.parse_string' do
    it 'creates a Package object with the right attributes' do
      package = Deb::S3::Package.parse_string(File.read(fixture('Packages')))
      expect(package.version).to eq '0.9.8.3'
      expect(package.epoch).to be_nil
      expect(package.iteration).to eq '1396474125.12e4179.wheezy'
      expect(package.full_version).to eq '0.9.8.3-1396474125.12e4179.wheezy'
      expect(package.description).to eq EXPECTED_DESCRIPTION
    end
  end

  describe '#full_version' do
    it 'returns nil if no version, epoch, iteration' do
      package = create_package
      expect(package.version).to be_nil
    end

    it 'returns only the version if no epoch and no iteration' do
      package = create_package version: '0.9.8'
      expect(package.full_version).to eq '0.9.8'
    end

    it 'returns epoch:version if epoch and version' do
      epoch = Time.now.to_i
      package = create_package version: '0.9.8', epoch: epoch
      expect(package.full_version).to eq "#{epoch}:0.9.8"
    end

    it 'returns version-iteration if version and iteration' do
      package = create_package version: '0.9.8', iteration: '2'
      expect(package.full_version).to eq '0.9.8-2'
    end

    it 'returns epoch:version-iteration if epoch and version and iteration' do
      epoch = Time.now.to_i
      package = create_package version: '0.9.8', iteration: '2', epoch: epoch
      expect(package.full_version).to eq "#{epoch}:0.9.8-2"
    end
  end
end
