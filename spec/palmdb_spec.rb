# frozen_string_literal: true

require 'spec_helper'
require 'time'

RSpec.shared_examples 'sample PalmDB' do # rubocop:disable Metrics/BlockLength
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
    expect(subject.type).to eq(Dyck::Mobi::TYPE_MAGIC)
  end

  it 'has creator' do
    expect(subject.creator).to eq(Dyck::Mobi::CREATOR_MAGIC)
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
    expect(subject.records[42].content).to start_with('w:0002?mime=text/css);/* @page is for EPUB2 only */')
  end
end

describe 'existing file' do
  subject do
    Dyck::PalmDB.read(fixture_file('sample-book.mobi'))
  end

  it_behaves_like 'sample PalmDB'
end

describe 'copy created by Dyck' do
  subject do
    original = Dyck::PalmDB.read(fixture_file('sample-book.mobi'))
    io = original.write(StringIO.new)
    io.seek(0)
    Dyck::PalmDB.read(io)
  end

  it_behaves_like 'sample PalmDB'
end

describe 'empty PalmDB' do
  subject { Dyck::PalmDB.new }

  it 'does not change after save/load' do
    io = subject.write(StringIO.new)
    io.seek(0)
    palmdb = Dyck::PalmDB.read(io)

    expect(Marshal.dump(palmdb)).to eq(Marshal.dump(subject))
  end
end
