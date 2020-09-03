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

  # A single KF7/KF8 metadata
  class MobiData
    NO_COMPRESSION = 1
    PALMDOC_COMPRESSION = 2
    HUFF_COMPRESSION = 17_480
    SUPPORTED_COMPRESSIONS = [NO_COMPRESSION].freeze
    attr_accessor(:compression)

    NO_ENCRYPTION = 0
    OLD_ENCRYPTION = 1
    MOBI_ENCRYPTION = 2
    SUPPORTED_ENCRYPTIONS = [NO_ENCRYPTION].freeze
    attr_accessor(:encryption)

    attr_accessor(:mobi_type)

    TEXT_ENCODING_CP1252 = 1252
    TEXT_ENCODING_UTF8 = 65_001
    SUPPORTED_TEXT_ENCODINGS = [TEXT_ENCODING_UTF8].freeze
    attr_accessor(:text_encoding)

    attr_accessor(:version)

    def initialize(
      compression: NO_COMPRESSION,
      encryption: NO_ENCRYPTION,
      mobi_type: 2,
      text_encoding: TEXT_ENCODING_UTF8,
      version: 6
    )
      @compression = compression
      @encryption = encryption
      @mobi_type = mobi_type
      @text_encoding = text_encoding
      @version = version
    end
  end

  # Represents a single Mobi file
  class Mobi # rubocop:disable Metrics/ClassLength
    # Max name length, including null terminating character
    NAME_LEN = 32
    TYPE_LEN = 4
    CREATOR_LEN = 4
    MOBI_MAGIC = 'MOBI'

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

    # @param name [String]
    # @param ctime [Time]
    # @param mtime [Time]
    # @param btime [Time]
    def initialize( # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      name: '',
      attributes: 0,
      version: 0,
      ctime: Time.now.utc,
      mtime: Time.now.utc,
      btime: Time.at(0).utc,
      mod_num: 0,
      appinfo_offset: 0,
      sortinfo_offset: 0,
      type: 'BOOK',
      creator: MOBI_MAGIC,
      uid: 0,
      next_rec: 0,
      records: []
    )
      raise ArgumentError, %(Unsupported type: #{type}) if type != 'BOOK'
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
      def read_io(io) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        mobi = Mobi.new(
          name: io.read(NAME_LEN).unpack1('Z*').encode('UTF-8'),
          attributes: io.read(2).unpack1('n'),
          version: io.read(2).unpack1('n'),
          ctime: Time.at(io.read(4).unpack1('N')).utc,
          mtime: Time.at(io.read(4).unpack1('N')).utc,
          btime: Time.at(io.read(4).unpack1('N')).utc,
          mod_num: io.read(4).unpack1('N'),
          appinfo_offset: io.read(4).unpack1('N'),
          sortinfo_offset: io.read(4).unpack1('N'),
          type: io.read(TYPE_LEN).unpack1('Z*').encode('UTF-8'),
          creator: io.read(CREATOR_LEN).unpack1('Z*').encode('UTF-8'),
          uid: io.read(4).unpack1('N'),
          next_rec: io.read(4).unpack1('N')
        )

        read_records(io, mobi)
        @kf7 = read_record0(mobi.records[0]) unless mobi.records.empty?
        mobi
      end

      def read_records(io, mobi) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        record_count = io.read(2).unpack1('n')
        record_offsets = []
        (0..record_count - 1).each do |_|
          record_offsets << io.read(4).unpack1('N')
          mobi.records << MobiRecord.new(
            attributes: io.read(1).unpack1('C'),
            uid: io.read(1).unpack1('C') << 16 | io.read(2).unpack1('n')
          )
        end
        io.seek(0, IO::SEEK_END)
        eof = io.tell
        mobi.records.each_with_index do |record, index|
          io.seek(record_offsets[index])
          end_offset = index < record_offsets.size - 1 ? record_offsets[index + 1] : eof
          record.body = io.read(end_offset - record_offsets[index])
        end
      end

      # @param record [Dyck::MobiRecord]
      # @return [Dyck::MobiData]
      def read_record0(record) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        raise ArgumentError, 'Expected at least 16 bytes in record0' if record.body.bytesize < 16

        io = StringIO.new(record.body)
        io.binmode

        result = MobiData.new
        result.compression = io.read(2).unpack1('n')
        unless MobiData::SUPPORTED_COMPRESSIONS.include? result.compression
          raise ArgumentError, %(Unsupported compression: #{result.compression})
        end

        io.read(2) # unused 2 bytes, zeroes
        _text_length = io.read(4).unpack1('N')
        _text_record_count = io.read(2).unpack1('n')
        _text_record_size = io.read(2).unpack1('n')

        result.encryption = io.read(2).unpack1('n')
        unless MobiData::SUPPORTED_ENCRYPTIONS.include? result.encryption
          raise ArgumentError, %(Unsupported encryption: #{result.encryption})
        end

        _unknown1 = io.read(2).unpack1('n')

        # Mobi header starts here

        magic = io.read(4)
        raise ArgumentError, %(Unsupported magic: #{magic}) if magic != MOBI_MAGIC

        header_length = io.read(4).unpack1('N')
        header = StringIO.new(io.read(header_length - 8))
        result.mobi_type = header.read(4).unpack1('N')

        result.text_encoding = header.read(4).unpack1('N')
        unless MobiData::SUPPORTED_TEXT_ENCODINGS.include?(result.text_encoding)
          raise ArgumentError, %(Unsupported text encoding: #{result.text_encoding})
        end

        _uid = header.read(4).unpack1('N')
        result.version = header.read(4).unpack1('N')

        # ignore all the rest header fields for now

        result
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

    def write_io(io) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      io.binmode
      io.write(@name.encode('ASCII')[0..NAME_LEN - 2].ljust(NAME_LEN, "\0"))
      io.write([@attributes].pack('n'))
      io.write([@version].pack('n'))
      io.write([@ctime.to_i].pack('N'))
      io.write([@mtime.to_i].pack('N'))
      io.write([@btime.to_i].pack('N'))
      io.write([@mod_num].pack('N'))
      io.write([@appinfo_offset].pack('N'))
      io.write([@sortinfo_offset].pack('N'))
      io.write(@type.encode('ASCII')[0..TYPE_LEN - 1].ljust(TYPE_LEN, "\0"))
      io.write(@creator.encode('ASCII')[0..CREATOR_LEN - 1].ljust(CREATOR_LEN, "\0"))
      io.write([@uid].pack('N'))
      io.write([@next_rec].pack('N'))

      @records << MobiRecord.new if @records.empty?
      update_record0(@kf7, @records[0])
      write_records(io)
    end

    # @param mobi_data [Dyck::MobiData]
    # @param record [Dyck::MobiRecord]
    def update_record0(mobi_data, record) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      io = StringIO.new
      io.binmode
      io.write([mobi_data.compression].pack('n'))
      io.write("\0\0")
      text_length = 0 # TODO
      io.write([text_length].pack('N'))
      text_record_count = 0 # TODO
      io.write([text_record_count].pack('n'))
      text_record_size = 4096
      io.write([text_record_size].pack('n'))
      io.write([mobi_data.encryption].pack('n'))
      unknown1 = 0
      io.write([unknown1].pack('n'))

      header_length = 24
      io.write(MOBI_MAGIC)
      io.write([header_length].pack('N'))
      io.write([mobi_data.mobi_type].pack('N'))
      io.write([mobi_data.text_encoding].pack('N'))
      uid = 0
      io.write([uid].pack('N'))
      io.write([mobi_data.version].pack('N'))

      record.body = io.string
    end

    def write_records(io) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      io.write([@records.size].pack('n'))
      # Write record headers
      offset = io.tell + 8 * @records.size
      @records.each do |record|
        io.write([offset].pack('N'))
        io.write([record.attributes].pack('C'))
        io.write([record.uid >> 16].pack('C'))
        io.write([record.uid & 0xFF].pack('n'))
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
