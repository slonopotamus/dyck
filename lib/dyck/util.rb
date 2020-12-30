# frozen_string_literal: true

module Dyck # rubocop:disable Style/Documentation
  MOBI_NOTSET = 0xffffffff

  # Assumes v is 32-bit long
  # @param value [Integer]
  # @return [Integer]
  def self.popcount(value)
    value -= ((value >> 1) & 0x55555555)
    value = (value & 0x33333333) + ((value >> 2) & 0x33333333)
    ((value + (value >> 4) & 0xF0F0F0F) * 0x1010101) >> 24
  end

  # @param value [Integer]
  # @param forward [Boolean]
  # @return [String]
  def self.encode_varlen(value, forward: true)
    raise ArgumentError('Cannot encode negative number as varlen') unless value >= 0

    bytes = []
    loop do
      b = value & 0b01111111
      value >>= 7
      bytes << b
      break if value.zero?
    end
    bytes[forward ? 0 : -1] |= 0b10000000
    bytes.reverse.pack('C*')
  end

  # @param data [String]
  # @param offset [Integer]
  # @param forward [Boolean]
  def self.decode_varlen(data, offset, forward: true) # rubocop:disable Metrics/MethodLength
    val = 0
    byte_count = 0
    stop_flag = 0x80
    mask = 0x7f
    shift = 0
    loop do
      byte = data[offset].unpack1('C')
      if forward
        offset += 1
        val <<= 7
        val |= (byte & mask)
      else
        offset -= 1
        val |= (byte & mask) << shift
        shift += 7
      end
      byte_count += 1

      break if (byte & stop_flag) != 0 || byte_count >= 4
    end
    [val, byte_count]
  end

  # @param data [String]
  # @param offset [Integer]
  def self.decode_varlen_dec(data, offset)
    decode_varlen(data, offset, forward: false)
  end
end
