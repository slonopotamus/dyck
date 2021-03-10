# frozen_string_literal: true

require 'spec_helper'
require 'time'

RSpec.shared_examples 'sample Mobi' do # rubocop:disable Metrics/BlockLength
  it 'is not nil' do
    expect(subject).not_to be_nil
  end

  it 'has title' do
    expect(subject.title).to eq('Asciidoctor Playground: Sample Content')
  end

  it 'has author' do
    expect(subject.author).to eq('Sarah White')
  end

  it 'has publisher' do
    expect(subject.publisher).to eq('Asciidoctor')
  end

  it 'has description' do
    expect(subject.description).to eq('This guide describes the Asciidoctor attributes, values, and layout options' \
      ' available for producing a customized and polished document.')
  end

  it 'has subjects' do
    expect(subject.subjects).to eq(%w[AsciiDoc Asciidoctor syntax reference])
  end

  it 'has publishing date' do
    expect(subject.publishing_date).to eq(Time.iso8601('2014-04-14T21:00:00Z'))
  end

  it 'has copyright' do
    expect(subject.copyright).to eq('CC-BY-SA 3.0')
  end

  it 'has MOBI6 header' do
    expect(subject.mobi6).not_to be_nil
    expect(subject.mobi6.compression).to eq(Dyck::MobiData::NO_COMPRESSION)
    expect(subject.mobi6.encryption).to eq(Dyck::MobiData::NO_ENCRYPTION)
    expect(subject.mobi6.mobi_type).to eq(2)
    expect(subject.mobi6.text_encoding).to eq(Dyck::MobiData::TEXT_ENCODING_UTF8)
  end

  it 'has MOBI6 part' do
    expect(subject.mobi6.parts.size).to eq(1)
    expect(subject.mobi6.parts[0].size).to eq(15_928)
  end

  it 'has KF8 header' do
    expect(subject.kf8).not_to be_nil
    expect(subject.kf8.compression).to eq(Dyck::MobiData::NO_COMPRESSION)
    expect(subject.kf8.encryption).to eq(Dyck::MobiData::NO_ENCRYPTION)
    expect(subject.kf8.mobi_type).to eq(2)
    expect(subject.kf8.text_encoding).to eq(Dyck::MobiData::TEXT_ENCODING_UTF8)
  end

  it 'has KF8 flow' do
    expect(subject.kf8.flow.size).to eq(5)
    expect(subject.kf8.flow[0].size).to eq(1_877)
    expect(subject.kf8.flow[4].size).to eq(44)
  end

  it 'has KF8 parts' do
    expect(subject.kf8.parts.size).to eq(10)
    expect(subject.kf8.parts[0].size).to eq(1_612)
    expect(subject.kf8.parts[9].size).to eq(3_060)
  end

  it 'has resources' do
    expect(subject.resources.size).to eq(19)
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

describe 'empty MOBI6' do
  subject { Dyck::Mobi.new(mobi6: Dyck::MobiData.new) }

  it 'does not change after save/load' do
    io = subject.write(StringIO.new)
    io.seek(0)
    mobi = Dyck::Mobi.read(io)

    expect(Marshal.dump(mobi)).to eq(Marshal.dump(subject))
  end

  it 'has MOBI6 header' do
    expect(subject.mobi6).not_to be_nil
  end
end

describe 'empty MOBI6+KF8' do
  subject do
    mobi = Dyck::Mobi.new(mobi6: Dyck::MobiData.new, kf8: Dyck::MobiData.new)
    io = mobi.write(StringIO.new)
    io.seek(0)
    Dyck::Mobi.read(io)
  end

  it 'has MOBI6 header with KF8 boundary' do
    expect(subject.mobi6).not_to be_nil
  end

  it 'has KF8 header' do
    expect(subject.kf8).not_to be_nil
  end
end

describe 'empty KF8' do
  subject do
    mobi = Dyck::Mobi.new(kf8: Dyck::MobiData.new)
    io = mobi.write(StringIO.new)
    io.seek(0)
    Dyck::Mobi.read(io)
  end

  it 'has KF8 header' do
    expect(subject.kf8).not_to be_nil
  end
end
