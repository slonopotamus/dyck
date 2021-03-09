# frozen_string_literal: true

require 'spec_helper'

RSpec.shared_examples 'frag index' do
  it 'has entries' do
    expect(subject.entries.size).to eq(10)
    entry = subject.entries[9]
    expect(entry.label).to eq('0000017634')
    expect(entry.tags.size).to eq(4)
    expect(entry.tag_value(Dyck::MobiData::INDX_TAG_FRAG_LENGTH)).to eq(2521)
  end
end

describe 'fixture frag index' do
  subject { read_fixture_idx('frag') }

  it_behaves_like 'frag index'
end

describe 'Dyck-generated frag index' do
  subject do
    orig = read_fixture_idx('frag')
    Dyck::Index.read(orig.write, orig.name)
  end

  it_behaves_like 'frag index'
end

RSpec.shared_examples 'skel index' do
  it 'has entries' do
    expect(subject.entries.size).to eq(10)
  end
end

describe 'fixture skel index' do
  subject { read_fixture_idx('skel') }

  it_behaves_like 'skel index'
end

describe 'Dyck-generated skel index' do
  subject do
    orig = read_fixture_idx('skel')
    Dyck::Index.read(orig.write, orig.name)
  end

  it_behaves_like 'skel index'
end
