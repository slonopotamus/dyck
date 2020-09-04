# frozen_string_literal: true

require 'spec_helper'
require 'time'

RSpec.shared_examples 'sample book' do # rubocop:disable Metrics/BlockLength
  it 'is not nil' do
    expect(subject).not_to be_nil
  end

  it 'has name' do
    expect(subject.name).to eq('Asciidoctor_-Sample_Content')
  end

  it 'has attributes' do
    expect(subject.attributes).to eq(0)
  end

  it 'has version' do
    expect(subject.version).to eq(0)
  end

  it 'has ctime' do
    expect(subject.ctime).to eq(Time.parse('2020-09-01 18:52:26 UTC'))
  end

  it 'has mtime' do
    expect(subject.mtime).to eq(Time.parse('2020-09-01 18:52:27 UTC'))
  end

  it 'has btime' do
    expect(subject.btime).to eq(Time.at(0))
  end

  it 'has mod_num' do
    expect(subject.mod_num).to eq(0)
  end

  it 'has appinfo_offset' do
    expect(subject.appinfo_offset).to eq(0)
  end

  it 'has sortinfo_offset' do
    expect(subject.appinfo_offset).to eq(0)
  end

  it 'has type' do
    expect(subject.type).to eq(Dyck::Mobi::BOOK_MAGIC)
  end

  it 'has creator' do
    expect(subject.creator).to eq(Dyck::Mobi::MOBI_MAGIC)
  end

  it 'has uid' do
    expect(subject.uid).to eq(123)
  end

  it 'has next_rec' do
    expect(subject.next_rec).to eq(0)
  end

  it 'has records' do
    expect(subject.records.size).to eq(61)
    expect(subject.records[42].uid).to eq(86)
    expect(subject.records[42].body).to start_with('w:0002?mime=text/css);/* @page is for EPUB2 only */')
  end

  it 'has KF7 header' do
    expect(subject.kf7).not_to be_nil
    expect(subject.kf7.compression).to eq(Dyck::Mobi::NO_COMPRESSION)
    expect(subject.kf7.encryption).to eq(Dyck::Mobi::NO_ENCRYPTION)
    expect(subject.kf7.mobi_type).to eq(2)
    expect(subject.kf7.text_encoding).to eq(Dyck::Mobi::TEXT_ENCODING_UTF8)
    expect(subject.kf7.version).to eq(6)
    expect(subject.kf7.exth_records.size).to eq(28)
    expect(subject.kf7.exth_records[2].tag).to eq(100)
    expect(subject.kf7.exth_records[2].data).to eq('Sarah White')
  end

  it 'has KF8 header' do
    expect(subject.kf8).not_to be_nil
    expect(subject.kf8.compression).to eq(Dyck::Mobi::NO_COMPRESSION)
    expect(subject.kf8.encryption).to eq(Dyck::Mobi::NO_ENCRYPTION)
    expect(subject.kf8.mobi_type).to eq(2)
    expect(subject.kf8.text_encoding).to eq(Dyck::Mobi::TEXT_ENCODING_UTF8)
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

  it_behaves_like 'sample book'
end

describe 'copy created by Dyck' do
  subject do
    original = Dyck::Mobi.read(fixture_file('sample-book.mobi'))
    io = original.write(StringIO.new)
    io.seek(0)
    Dyck::Mobi.read(io)
  end

  it_behaves_like 'sample book'
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
    expect(subject.kf7.find_exth(Dyck::ExthRecord::EXTH_KF8BOUNDARY)).not_to be_nil
  end

  it 'has KF8 header' do
    expect(subject.kf8).not_to be_nil
    expect(subject.kf8.version).to eq(8)
  end
end
