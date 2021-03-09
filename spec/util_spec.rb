# frozen_string_literal: true

require 'spec_helper'

describe 'util' do
  it 'encodes_decodes_varlen_zero' do
    encoded = Dyck.encode_varlen(0)
    decoded, = Dyck.decode_varlen(encoded, 0)
    expect(decoded).to eq(0)
  end

  it 'encodes_decodes_varlen_one' do
    encoded = Dyck.encode_varlen(1)
    decoded, = Dyck.decode_varlen(encoded, 0)
    expect(decoded).to eq(1)
  end

  it 'encodes_decodes_varlen_255' do
    encoded = Dyck.encode_varlen(255)
    decoded, = Dyck.decode_varlen(encoded, 0)
    expect(decoded).to eq(255)
  end
end
