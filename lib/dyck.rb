# frozen_string_literal: true

require 'dyck/version'

module Dyck
  # A single data record within Mobi file
  class MobiRecord
    attr_accessor(:attributes)
    attr_accessor(:uid)
    attr_accessor(:body)

    def initialize(attributes: 0, uid: 0, body: '')
      @attributes = attributes
      @uid = uid
      @body = body
    end
  end

  # A single EXTH metadata record
  class ExthRecord
    EXTH_KF8BOUNDARY = 121
    # TODO: constants for tag types
    attr_reader(:tag)
    attr_accessor(:data)

    def initialize(tag: 1, data: '')
      @tag = tag
      @data = data
    end

    def data_uint16
      @data.unpack1('N')
    end
  end

  # A single KF7/KF8 metadata
  class MobiData
    attr_accessor(:compression)

    attr_accessor(:encryption)

    attr_accessor(:mobi_type)

    attr_accessor(:text_encoding)

    attr_accessor(:version)
    attr_reader(:exth_records)

    def initialize( # rubocop:disable Metrics/ParameterLists
      compression: Mobi::NO_COMPRESSION,
      encryption: Mobi::NO_ENCRYPTION,
      mobi_type: 2,
      text_encoding: Mobi::TEXT_ENCODING_UTF8,
      version: 6,
      exth_records: []
    )
      @compression = compression
      @encryption = encryption
      @mobi_type = mobi_type
      @text_encoding = text_encoding
      @version = version
      @exth_records = exth_records
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
  end

  # Represents a single Mobi file
  class Mobi # rubocop:disable Metrics/ClassLength
    # Max name length, including null terminating character
    NAME_LEN = 32
    TYPE_LEN = 4
    CREATOR_LEN = 4
    BOOK_MAGIC = 'BOOK'.b
    MOBI_MAGIC = 'MOBI'.b
    EXTH_MAGIC = 'EXTH'.b
    PALMDB_HEADER = %(A#{NAME_LEN}nnNNNNNNa#{TYPE_LEN}a#{CREATOR_LEN}NNn)

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

    # @return [String]
    attr_accessor(:name)
    attr_accessor(:attributes)
    attr_accessor(:version)
    # @return [Time]
    attr_accessor(:ctime)
    # @return [Time]
    attr_accessor(:mtime)
    # @return [Time]
    attr_accessor(:btime)
    attr_accessor(:mod_num)
    attr_accessor(:appinfo_offset)
    attr_accessor(:sortinfo_offset)
    # @return [String]
    attr_reader(:type)
    # @return [String]
    attr_reader(:creator)
    attr_accessor(:uid)
    attr_accessor(:next_rec)
    # @return [Array<Dyck::MobiRecord>]
    attr_reader(:records)
    # @return [Dyck::MobiData]
    attr_accessor(:kf7)
    # @return [Dyck::ExthRecord]
    attr_accessor(:kf8_boundary)
    # @return [Dyck::MobiData]
    attr_accessor(:kf8)

    # @param name [String]
    # @param ctime [Time]
    # @param mtime [Time]
    # @param btime [Time]
    def initialize( # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
      name: '', attributes: 0, version: 0, ctime: Time.now.utc, mtime: Time.now.utc, btime: Time.at(0).utc, mod_num: 0,
      appinfo_offset: 0, sortinfo_offset: 0, type: BOOK_MAGIC, creator: MOBI_MAGIC, uid: 0, next_rec: 0, records: []
    )
      raise ArgumentError, %(Unsupported type: #{type}) if type != BOOK_MAGIC
      raise ArgumentError, %(Unsupported creator: #{type}) if creator != MOBI_MAGIC

      @name = name
      @attributes = attributes
      @version = version
      @ctime = ctime.round
      @mtime = mtime.round
      @btime = btime.round
      @mod_num = mod_num
      @appinfo_offset = appinfo_offset
      @sortinfo_offset = sortinfo_offset
      @type = type
      @creator = creator
      @uid = uid
      @next_rec = next_rec
      @records = records
      @kf7 = MobiData.new
      @kf8_boundary = nil
      @kf8 = nil
    end

    class << self
      # @return [Dyck::Mobi]
      def read(filename_or_io)
        if filename_or_io.respond_to? :seek
          read_io(filename_or_io)
        else
          File.open(filename_or_io, 'rb') do |io|
            read_io(io)
          end
        end
      end

      private

      # @param io [IO]
      # @return [Dyck::Mobi]
      def read_io(io) # rubocop:disable Metrics/AbcSize
        name, attributes, version, ctime, mtime, btime, mod_num, appinfo_offset, sortinfo_offset, type, creator, uid,
            next_rec, record_count = io.read(78).unpack(PALMDB_HEADER)
        mobi = Mobi.new(
          name: name.encode('UTF-8'), attributes: attributes, version: version, ctime: Time.at(ctime).utc,
          mtime: Time.at(mtime).utc, btime: Time.at(btime).utc, mod_num: mod_num, appinfo_offset: appinfo_offset,
          sortinfo_offset: sortinfo_offset, type: type, creator: creator, uid: uid, next_rec: next_rec
        )
        read_records(mobi, io, record_count)
        mobi
      end

      def read_records(mobi, io, record_count) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        record_offsets = []
        (0..record_count - 1).each do |index|
          record_offsets[index], attributes, uid_high, uid_low = io.read(8).unpack('NCCn')
          mobi.records << MobiRecord.new(attributes: attributes, uid: uid_high | uid_low)
        end
        io.seek(0, IO::SEEK_END)
        eof = io.tell
        mobi.records.each_with_index do |record, index|
          io.seek(record_offsets[index])
          end_offset = index < record_offsets.size - 1 ? record_offsets[index + 1] : eof
          record.body = io.read(end_offset - record_offsets[index])
        end
        mobi.kf7 = read_record0(mobi.records[0]) unless mobi.records.empty?

        mobi.kf8_boundary = mobi.kf7.find_exth(ExthRecord::EXTH_KF8BOUNDARY)
        return if mobi.kf8_boundary.nil?

        mobi.kf8 = read_record0(mobi.records[mobi.kf8_boundary.data_uint16])
      end

      # @param record [Dyck::MobiRecord]
      # @return [Dyck::MobiData]
      def read_record0(record) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        io = StringIO.new(record.body)
        io.binmode

        result = MobiData.new
        result.compression, _zero, _text_length, _text_record_count, _text_record_size, result.encryption, _unknown1 =
          io.read(16).unpack('nnNn*')
        unless Mobi::SUPPORTED_COMPRESSIONS.include? result.compression
          raise ArgumentError, %(Unsupported compression: #{result.compression})
        end
        unless Mobi::SUPPORTED_ENCRYPTIONS.include? result.encryption
          raise ArgumentError, %(Unsupported encryption: #{result.encryption})
        end

        read_mobi_header(result, io)
        read_exth_header(result, io)

        result
      end

      def read_mobi_header(mobi_record, io)
        magic = io.read(4)
        raise ArgumentError, %(Unsupported magic: #{magic}) if magic != MOBI_MAGIC

        mobi_header_length = io.read(4).unpack1('N') - 8
        mobi_header = StringIO.new(io.read(mobi_header_length))
        mobi_record.mobi_type, mobi_record.text_encoding, _uid, mobi_record.version = mobi_header.read(16).unpack('N*')

        unless Mobi::SUPPORTED_TEXT_ENCODINGS.include?(mobi_record.text_encoding) # rubocop:disable Style/GuardClause
          raise ArgumentError, %(Unsupported text encoding: #{mobi_record.text_encoding})
        end

        # ignore all the rest Mobi header fields for now
      end

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

    def write(filename_or_io)
      if filename_or_io.respond_to? :write
        write_io(filename_or_io)
      else
        File.open(filename_or_io, 'wb') do |io|
          write_io(io)
        end
      end
    end

    private

    def write_io(io)
      @records << MobiRecord.new if @records.empty?
      update_kf8_boundary
      update_record0(@kf7, @records[0])
      io.binmode
      io.write([
        @name, @attributes, @version, @ctime.to_i, @mtime.to_i, @btime.to_i, @mod_num, @appinfo_offset,
        @sortinfo_offset, @type, @creator, @uid, @next_rec, @records.size
      ].pack(PALMDB_HEADER))
      write_records(io)
    end

    def update_kf8_boundary
      if @kf8
        @records << MobiRecord.new unless @kf8_boundary
        update_record0(@kf8, @records[-1])
        @kf8_boundary = @kf7.set_exth(ExthRecord::EXTH_KF8BOUNDARY, [@records.size - 1].pack('N'))
      elsif @kf8_boundary
        @records.delete_at(@kf8_boundary.data_uint16)
        @kf8_boundary = nil
        @kf7.remove_exth(ExthRecord::EXTH_KF8BOUNDARY)
      end
    end

    # @param mobi_data [Dyck::MobiData]
    # @param record [Dyck::MobiRecord]
    def update_record0(mobi_data, record)
      io = StringIO.new
      io.binmode
      text_length = 0 # TODO
      text_record_count = 0 # TODO
      text_record_size = 4096
      io.write([mobi_data.compression, 0, text_length, text_record_count, text_record_size, mobi_data.encryption, 0]
                   .pack('nnNn*'))

      write_mobi_header(mobi_data, io)
      write_exth_header(mobi_data, io)

      record.body = io.string
    end

    def write_mobi_header(mobi_data, io)
      header_length = 24
      uid = 0
      io.write(
        [MOBI_MAGIC, header_length, mobi_data.mobi_type, mobi_data.text_encoding, uid, mobi_data.version] .pack('a*N*')
      )
    end

    # @param mobi_data [Dyck::MobiData]
    # @param io [StringIO]
    def write_exth_header(mobi_data, io) # rubocop:disable Metrics/AbcSize
      io.write(EXTH_MAGIC)

      exth_header_length = 12
      mobi_data.exth_records.each do |exth_record|
        exth_header_length += exth_record.data.bytesize + 8
      end
      io.write([exth_header_length, mobi_data.exth_records.size].pack('N*'))
      mobi_data.exth_records.each do |exth_record|
        io.write([exth_record.tag, exth_record.data.bytesize + 8, exth_record.data].pack('NNa*'))
      end
    end

    def write_records(io) # rubocop:disable Metrics/AbcSize
      # Write record headers
      offset = io.tell + 8 * @records.size
      @records.each do |record|
        io.write([offset, record.attributes, record.uid >> 16, record.uid & 0xFF].pack('NCCn'))
        offset += record.body.bytesize
      end
      # Write record bodies
      @records.each do |record|
        io.write(record.body)
      end
      io
    end
  end
end
