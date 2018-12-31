# frozen_string_literal: true

require File.expand_path('../../spec_helper', __dir__)

require 'deb/s3/utils'
require 'deb/s3/lock'

describe Deb::S3::Lock do
  describe :locked? do
    it 'returns true if lock file exists' do
      allow(Deb::S3::Utils).to receive(:s3_exists?) { true }
      expect(Deb::S3::Lock.locked?('stable')).to be_truthy
    end

    it 'returns true if lock file exists' do
      allow(Deb::S3::Utils).to receive(:s3_exists?) { false }
      expect(Deb::S3::Lock.locked?('stable')).to be_falsey
    end
  end

  describe :lock do
    it 'creates a lock file' do
      allow(Deb::S3::Utils).to receive(:s3_store).with(any_args)
      allow(Deb::S3::Utils).to receive(:s3_read) { "foo@bar\nabcde" }
      allow(Deb::S3::Lock).to receive(:generate_lock_content) { "foo@bar\nabcde" }

      expect(Deb::S3::Utils).to receive(:s3_read).once
      expect(Deb::S3::Lock).to receive(:generate_lock_content).once
      expect(Deb::S3::Utils).to receive(:s3_store).once

      Deb::S3::Lock.lock('stable')
    end
  end

  describe :unlock do
    it 'deletes the lock file' do
      allow(Deb::S3::Utils).to receive(:s3_remove) { nil }
      expect(Deb::S3::Utils).to receive(:s3_remove).once
      Deb::S3::Lock.unlock('stable')
    end
  end

  describe :current do
    before :each do
      allow(Deb::S3::Utils).to receive(:s3_read) { 'alex@localhost' }
      expect(Deb::S3::Utils).to receive(:s3_read).once
      @lock = Deb::S3::Lock.current('stable')
    end

    it 'returns a lock object' do
      expect(@lock).to be_a Deb::S3::Lock
    end

    it 'holds the user who currently holds the lock' do
      expect(@lock.user).to eq 'alex'
    end

    it 'holds the hostname from where the lock was set' do
      expect(@lock.host).to eq 'localhost'
    end
  end
end
