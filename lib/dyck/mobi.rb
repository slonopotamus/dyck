# frozen_string_literal: true

require 'dyck/palmdb'

module Dyck
  # A single EXTH metadata record
  class ExthRecord
    KF8_BOUNDARY = 121

    # TODO: constants for tag types
    attr_reader(:tag)
    attr_accessor(:data)

    def initialize(tag: 1, data: '')
      @tag = tag
      @data = data
    end

    def data_uint32
      @data.unpack1('N')
    end
  end

  # A single KF7/KF8 data
  class MobiData # rubocop:disable Metrics/ClassLength
    NO_COMPRESSION = 1
    PALMDOC_COMPRESSION = 2
    HUFF_COMPRESSION = 17_480
    SUPPORTED_COMPRESSIONS = [NO_COMPRESSION].freeze

    NO_ENCRYPTION = 0
    OLD_ENCRYPTION = 1
    MOBI_ENCRYPTION = 2
    SUPPORTED_ENCRYPTIONS = [NO_ENCRYPTION].freeze

    TEXT_ENCODING_CP1252 = 1252
    TEXT_ENCODING_UTF8 = 65_001
    SUPPORTED_TEXT_ENCODINGS = [TEXT_ENCODING_UTF8].freeze

    MOBI_MAGIC = 'MOBI'.b
    EXTH_MAGIC = 'EXTH'.b

    MAX_RECORD_SIZE = 4096

    attr_accessor(:compression)
    attr_accessor(:encryption)
    attr_accessor(:mobi_type)
    attr_accessor(:text_encoding)
    attr_accessor(:version)
    # @return [Array<Dyck::ExthRecord>]
    attr_reader(:exth_records)
    # @return [String]
    attr_accessor(:content)

    def initialize( # rubocop:disable Metrics/ParameterLists
      compression: NO_COMPRESSION,
      encryption: NO_ENCRYPTION,
      mobi_type: 2,
      text_encoding: TEXT_ENCODING_UTF8,
      version: 6,
      exth_records: [],
      content: ''.b
    )
      @compression = compression
      @encryption = encryption
      @mobi_type = mobi_type
      @text_encoding = text_encoding
      @version = version
      @exth_records = exth_records
      @content = content
    end

    def content_chunks
      content.bytes.each_slice(MobiData::MAX_RECORD_SIZE).map do |chunk|
        PalmDBRecord.new(content: chunk.pack('c*'))
      end
    end

    class << self
      # @param records [Array<Dyck::PalmDBRecord>]
      # @return [Dyck::MobiData]
      def read(records, index) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        io = StringIO.new(records[index].content)
        io.binmode

        result = MobiData.new
        result.compression, _zero, _text_length, text_record_count, _text_record_size, result.encryption, _unknown1 =
          io.read(16).unpack('nnNn*')
        unless SUPPORTED_COMPRESSIONS.include? result.compression
          raise ArgumentError, %(Unsupported compression: #{result.compression})
        end
        unless SUPPORTED_ENCRYPTIONS.include? result.encryption
          raise ArgumentError, %(Unsupported encryption: #{result.encryption})
        end

        extra_flags = read_mobi_header(result, io)
        read_exth_header(result, io)

        (1..text_record_count).each do |idx|
          content = records[index + idx].content
          extra_size = get_record_extra_size(content, extra_flags)
          bytesize = content.bytesize
          len = bytesize - extra_size
          result.content += content[0..len - 1]
        end

        result
      end

      private

      # @param data [String]
      # @param offset [Fixnum]
      def get_varlen_dec(data, offset)
        bitpos = 0
        result = 0
        loop do
          v = data[offset - 1].unpack1('C')
          result |= (v & 0x7F) << bitpos
          bitpos += 7
          offset -= 1
          return result if (v & 0x80) != 0 || offset.zero?
        end
      end

      # @param data [String]
      # @param extra_flags [Fixnum]
      def get_record_extra_size(data, extra_flags)
        num = 0
        size = data.size
        flags = extra_flags >> 1
        while flags != 0
          num += get_varlen_dec(data, size - num) if (flags & 1) != 0
          flags >>= 1
        end
        num += (data[size - num - 1].unpack1('C') & 0x3) + 1 if (extra_flags & 1) != 0
        num
      end

      # @param mobi_data [Dyck::MobiData]
      # @param io [IO, StringIO]
      def read_mobi_header(mobi_data, io) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        magic = io.read(4)
        raise ArgumentError, %(Unsupported magic: #{magic}) if magic != MOBI_MAGIC

        mobi_header_length = io.read(4).unpack1('N') - 8
        mobi_header = StringIO.new(io.read(mobi_header_length))
        mobi_data.mobi_type, mobi_data.text_encoding, _uid, mobi_data.version = mobi_header.read(16).unpack('N*')

        # ignore all the rest Mobi header fields for now
        mobi_header.seek(202, IO::SEEK_CUR)
        extra_flags = mobi_header.read(2)&.unpack1('n') || 0
        # there are more fields *after* extra_flags

        unless SUPPORTED_TEXT_ENCODINGS.include?(mobi_data.text_encoding)
          raise ArgumentError, %(Unsupported text encoding: #{mobi_data.text_encoding})
        end

        extra_flags
      end

      # @param mobi_data [Dyck::MobiData]
      # @param io [IO, StringIO]
      def read_exth_header(mobi_data, io) # rubocop:disable Metrics/AbcSize
        exth = io.read(4)
        raise ArgumentError, %(Unsupported EXTH: #{exth}) if exth != EXTH_MAGIC

        exth_header_length, exth_record_count = io.read(8).unpack('N*')
        exth_header = StringIO.new(io.read(exth_header_length - 12))
        (0..exth_record_count - 1).each do |_|
          tag, data_len = exth_header.read(8).unpack('N*')
          data = exth_header.read(data_len - 8)
          mobi_data.exth_records << ExthRecord.new(tag: tag, data: data)
        end
      end
    end

    # @param record [Dyck::PalmDBRecord]
    def write(record, text_record_count)
      io = StringIO.new
      io.binmode
      text_length = 0 # TODO
      io.write([compression, 0, text_length, text_record_count, MAX_RECORD_SIZE, encryption, 0].pack('nnNn*'))

      write_mobi_header(io)
      write_exth_header(io)

      record.content = io.string
    end

    def set_exth(tag, data)
      record = find_exth(tag)
      if record.nil?
        @exth_records << ExthRecord.new(tag: tag, data: data)
      else
        record.data = data
      end
    end

    def remove_exth(tag)
      @exth_records.reject! { |record| record.tag == tag }
    end

    def find_exth(tag)
      @exth_records.detect { |record| record.tag == tag }
    end

    private

    # @param io [IO, StringIO]
    def write_mobi_header(io)
      header_length = 24
      uid = 0
      io.write([MOBI_MAGIC, header_length, @mobi_type, @text_encoding, uid, @version].pack('a*N*'))
    end

    # @param io [IO, StringIO]
    def write_exth_header(io)
      io.write(EXTH_MAGIC)

      exth_header_length = 12
      @exth_records.each do |exth_record|
        exth_header_length += exth_record.data.bytesize + 8
      end
      io.write([exth_header_length, @exth_records.size].pack('N*'))
      @exth_records.each do |exth_record|
        io.write([exth_record.tag, exth_record.data.bytesize + 8, exth_record.data].pack('NNa*'))
      end
    end
  end

  # Represents a single Mobi file
  class Mobi
    TYPE_MAGIC = 'BOOK'.b
    CREATOR_MAGIC = 'MOBI'.b

    # @return [Dyck::MobiData]
    attr_accessor(:kf7)
    # @return [Dyck::MobiData]
    attr_accessor(:kf8)

    # @param kf7 [Dyck::MobiData]
    # @param kf8 [Dyck::MobiData, nil]
    def initialize(kf7: MobiData.new, kf8: nil)
      @kf7 = kf7
      @kf8 = kf8
    end

    class << self
      # @return [Dyck::Mobi]
      def read(filename_or_io)
        palmdb = PalmDB.read(filename_or_io)
        from_palmdb(palmdb)
      end

      # @param palmdb [Dyck::PalmDB]
      # @return [Dyck::Mobi]
      def from_palmdb(palmdb) # rubocop:disable Metrics/AbcSize
        raise ArgumentError, %(Unsupported type: #{palmdb.type}) if palmdb.type != TYPE_MAGIC
        raise ArgumentError, %(Unsupported creator: #{palmdb.type}) if palmdb.creator != CREATOR_MAGIC

        kf7 = palmdb.records.empty? ? MobiData.new : MobiData.read(palmdb.records, 0)

        kf8_boundary = kf7.find_exth(ExthRecord::KF8_BOUNDARY)
        kf8 = kf8_boundary.nil? ? nil : MobiData.read(palmdb.records, kf8_boundary.data_uint32)

        Mobi.new(kf7: kf7, kf8: kf8)
      end
    end

    def write(filename_or_io)
      to_palmdb.write(filename_or_io)
    end

    # @return [Dyck::PalmDB]
    def to_palmdb # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      palmdb = PalmDB.new(type: TYPE_MAGIC, creator: CREATOR_MAGIC)
      palmdb.records << (kf7_header = PalmDBRecord.new)
      palmdb.records.concat(kf7_content_chunks = @kf7.content_chunks)

      @kf7.remove_exth(ExthRecord::KF8_BOUNDARY)
      if @kf8
        @kf7.set_exth(ExthRecord::KF8_BOUNDARY, [palmdb.records.size].pack('N'))
        palmdb.records << (kf8_header = PalmDBRecord.new)
        palmdb.records.concat(kf8_content_chunks = @kf8.content_chunks)
        @kf8.write(kf8_header, kf8_content_chunks.size)
      end
      @kf7.write(kf7_header, kf7_content_chunks.size)
      palmdb
    end
  end
end
