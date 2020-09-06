# frozen_string_literal: true

require 'spec_helper'
require 'time'

RSpec.shared_examples 'sample Mobi' do
  it 'is not nil' do
    expect(subject).not_to be_nil
  end

  it 'has KF7 header' do
    expect(subject.kf7).not_to be_nil
    expect(subject.kf7.compression).to eq(Dyck::MobiData::NO_COMPRESSION)
    expect(subject.kf7.encryption).to eq(Dyck::MobiData::NO_ENCRYPTION)
    expect(subject.kf7.mobi_type).to eq(2)
    expect(subject.kf7.text_encoding).to eq(Dyck::MobiData::TEXT_ENCODING_UTF8)
    expect(subject.kf7.version).to eq(6)
    expect(subject.kf7.exth_records.size).to eq(28)
    expect(subject.kf7.exth_records[2].tag).to eq(100)
    expect(subject.kf7.exth_records[2].data).to eq('Sarah White')
  end

  it 'has KF8 header' do
    expect(subject.kf8).not_to be_nil
    expect(subject.kf8.compression).to eq(Dyck::MobiData::NO_COMPRESSION)
    expect(subject.kf8.encryption).to eq(Dyck::MobiData::NO_ENCRYPTION)
    expect(subject.kf8.mobi_type).to eq(2)
    expect(subject.kf8.text_encoding).to eq(Dyck::MobiData::TEXT_ENCODING_UTF8)
    expect(subject.kf8.version).to eq(8)
    expect(subject.kf8.exth_records.size).to eq(27)
    expect(subject.kf8.exth_records[2].tag).to eq(100)
    expect(subject.kf8.exth_records[2].data).to eq('Sarah White')
  end
end

describe 'existing file' do
  subject do
    Dyck::Mobi.read(fixture_file('sample-book.mobi'))
  end

  it_behaves_like 'sample Mobi'
end

describe 'copy created by Dyck' do
  subject do
    original = Dyck::Mobi.read(fixture_file('sample-book.mobi'))
    io = original.write(StringIO.new)
    io.seek(0)
    Dyck::Mobi.read(io)
  end

  it_behaves_like 'sample Mobi'
end

describe 'empty Mobi' do
  subject { Dyck::Mobi.new }

  it 'does not change after save/load' do
    io = subject.write(StringIO.new)
    io.seek(0)
    mobi = Dyck::Mobi.read(io)

    expect(Marshal.dump(mobi)).to eq(Marshal.dump(subject))
  end

  it 'has KF7 header' do
    expect(subject.kf7).not_to be_nil
  end
end

describe 'empty KF8 Mobi' do
  subject do
    mobi = Dyck::Mobi.new
    mobi.kf8 = Dyck::MobiData.new(version: 8)
    io = mobi.write(StringIO.new)
    io.seek(0)
    Dyck::Mobi.read(io)
  end

  it 'has KF7 header with KF8 boundary' do
    expect(subject.kf7).not_to be_nil
    expect(subject.kf7.find_exth(Dyck::ExthRecord::KF8_BOUNDARY)).not_to be_nil
  end

  it 'has KF8 header' do
    expect(subject.kf8).not_to be_nil
    expect(subject.kf8.version).to eq(8)
  end
end
