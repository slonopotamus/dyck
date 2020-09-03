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
    expect(subject.type).to eq('BOOK')
  end

  it 'has creator' do
    expect(subject.creator).to eq('MOBI')
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

  it 'has kf7' do
    expect(subject.kf7).not_to be_nil
    expect(subject.kf7.compression).to eq(Dyck::MobiData::NO_COMPRESSION)
    expect(subject.kf7.encryption).to eq(Dyck::MobiData::NO_ENCRYPTION)
    expect(subject.kf7.mobi_type).to eq(2)
    expect(subject.kf7.text_encoding).to eq(Dyck::MobiData::TEXT_ENCODING_UTF8)
    expect(subject.kf7.version).to eq(6)
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
  it 'can save and load' do
    original = Dyck::Mobi.new
    io = original.write(StringIO.new)
    io.seek(0)
    mobi = Dyck::Mobi.read(io)

    expect(Marshal.dump(mobi)).to eq(Marshal.dump(original))
  end
end
