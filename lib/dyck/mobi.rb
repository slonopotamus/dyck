# frozen_string_literal: true

require 'dyck/palmdb'
require 'time'

module Dyck
  MobiResource = Struct.new(:type, :content)

  # A single EXTH metadata record
  class ExthRecord
    AUTHOR = 100
    PUBLISHER = 101
    DESCRIPTION = 103
    SUBJECT = 105
    PUBLISHING_DATE = 106
    RIGHTS = 109
    KF8_BOUNDARY = 121

    attr_reader(:tag)
    attr_accessor(:data)

    def initialize(tag: 0, data: ''.b)
      @tag = tag
      @data = data
    end

    def data_uint32
      @data.unpack1('N')
    end

    class << self
      # @param tag [Fixnum]
      # @param records [Array<Dyck::ExthRecord>]
      def find(tag, records)
        records.detect { |record| record.tag == tag }
      end
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

    FDST_MAGIC = 'FDST'.b
    FDST_HEADER = %(A#{FDST_MAGIC.bytesize}NN)

    MAX_RECORD_SIZE = 4096

    MOBI_NOTSET = 0xffffffff

    attr_accessor(:compression)
    attr_accessor(:encryption)
    attr_accessor(:mobi_type)
    attr_accessor(:text_encoding)
    attr_accessor(:version)
    # @return [Array<String>]
    attr_accessor(:flow)

    def initialize( # rubocop:disable Metrics/ParameterLists
      compression: NO_COMPRESSION,
      encryption: NO_ENCRYPTION,
      mobi_type: 2,
      text_encoding: TEXT_ENCODING_UTF8,
      version: 8,
      flow: []
    )
      @compression = compression
      @encryption = encryption
      @mobi_type = mobi_type
      @text_encoding = text_encoding
      @version = version
      @flow = flow
    end

    class << self
      # @param records [Array<Dyck::PalmDBRecord>]
      # @param index [Fixnum]
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

        extra_flags, fdst_index, fdst_section_count, image_index, full_name = read_mobi_header(result, io)
        exth_records = read_exth_header(io)

        content = read_content(index + 1, text_record_count, records, extra_flags)
        fdst = read_fdst(fdst_index, index, records, fdst_section_count)
        result.flow = reconstruct_flow(content, fdst)

        [result, image_index, exth_records, full_name]
      end

      private

      # @param content [String]
      # @param fdst [Array<Range>, nil]
      # @return [Array<String>]
      def reconstruct_flow(content, fdst)
        return [] if content.empty?
        return [content] if fdst.nil?

        fdst.map do |range|
          content[range.begin..range.end - 1]
        end
      end

      # @param offset [Fixnum]
      # @param count [Fixnum]
      # @param records [Array<PalmDBRecord>]
      # @return [String]
      def read_content(offset, count, records, extra_flags)
        content = ''.b
        (0..count - 1).each do |idx|
          record_content = records[offset + idx].content
          extra_size = get_record_extra_size(record_content, extra_flags)
          content += record_content[0..record_content.bytesize - extra_size - 1]
        end
        content
      end

      # @param fdst_index [Fixnum, nil]
      # @param offset [Fixnum]
      # @param records [Array<Dyck::PalmDBRecord>]
      # @return [Array<Range>]
      def read_fdst(fdst_index, offset, records, fdst_section_count)
        return nil if fdst_index.nil? || fdst_section_count.nil? || fdst_section_count <= 1

        fdst_record = records[offset + fdst_index]
        io = StringIO.new(fdst_record.content)
        magic, _data_offset, _section_count = io.read(12).unpack(FDST_HEADER)
        raise ArgumentError, %(Unsupported FDST magic: #{magic}) if magic != FDST_MAGIC

        (0..fdst_section_count - 1).map do |_|
          start, end_ = io.read(8).unpack('NN')
          (start..end_)
        end
      end

      # @param data [String]
      # @param offset [Fixnum]
      # @return [Fixnum]
      def get_varlen_dec(data, offset)
        bitpos = 0
        result = 0
        loop do
          v = data[offset - 1].unpack1('C')
          result |= (v & 0x7F) << bitpos
          bitpos += 7
          offset -= 1
          break if (v & 0x80) != 0 || offset.zero?
        end
        result
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
      def read_mobi_header(mobi_data, io) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        magic = io.read(4)
        raise ArgumentError, %(Unsupported magic: #{magic}) if magic != MOBI_MAGIC

        mobi_header_length = io.read(4).unpack1('N')
        mobi_header = StringIO.new(io.read(mobi_header_length - 8))
        mobi_data.mobi_type, mobi_data.text_encoding, _uid, mobi_data.version, = mobi_header.read(15 * 4).unpack('N*')

        unless SUPPORTED_TEXT_ENCODINGS.include?(mobi_data.text_encoding)
          raise ArgumentError, %(Unsupported text encoding: #{mobi_data.text_encoding})
        end

        # there are more fields here
        full_name_offset, full_name_length, = mobi_header.read(5 * 4)&.unpack('N*')
        pos = io.tell
        io.seek(full_name_offset)
        full_name = io.read(full_name_length)
        io.seek(pos)
        # there are more fields here
        _min_version, image_index, = mobi_header.read(22 * 4)&.unpack('N*')
        # there are more fields here
        if mobi_data.version >= 8
          fdst_index = mobi_header.read(4)&.unpack1('N')
        else
          # Assume that last_text_index is fdst_index for KF7
          _, fdst_index = mobi_header.read(4)&.unpack('nn')
        end
        fdst_section_count = mobi_header.read(4)&.unpack1('N')
        # there are more fields here
        mobi_header.seek(42, IO::SEEK_CUR)
        extra_flags = mobi_header.read(2)&.unpack1('n') || 0
        # there are more fields here

        [extra_flags, fdst_index, fdst_section_count, image_index, full_name]
      end

      # @param io [IO, StringIO]
      # @return [Array<Dyck::ExthRecord]
      def read_exth_header(io)
        exth = io.read(4)
        raise ArgumentError, %(Unsupported EXTH: #{exth}) if exth != EXTH_MAGIC

        exth_header_length, exth_record_count = io.read(8).unpack('N*')
        exth_header = StringIO.new(io.read(exth_header_length - 12))
        (0..exth_record_count - 1).map do |_|
          tag, data_len = exth_header.read(8).unpack('N*')
          data = exth_header.read(data_len - 8)
          ExthRecord.new(tag: tag, data: data)
        end
      end
    end

    # @param header_record [Dyck::PalmDBRecord]
    # @param text_length [Fixnum]
    # @param text_record_count [Fixnum]
    # @param fdst_index [Fixnum]
    # @param image_index [Fixnum]
    # @param exth_records [Array<Dyck::ExthRecord>]
    def write(header_record, text_length, text_record_count, fdst_index, image_index, exth_records, full_name) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
      io = StringIO.new
      io.binmode
      io.write([compression, 0, text_length, text_record_count, MAX_RECORD_SIZE, encryption, 0].pack('nnNn*'))

      exth_buf = StringIO.new
      exth_buf.binmode
      write_exth_header(exth_buf, exth_records)

      write_mobi_header(io, fdst_index, @flow.size, image_index, exth_buf.size, full_name)
      io.write(exth_buf.string)
      io.write(full_name)
      io.write("\0")

      header_record.content = io.string
    end

    def content_chunks
      bytes = @flow.join.bytes
      [bytes.each_slice(MobiData::MAX_RECORD_SIZE).map do |chunk|
        PalmDBRecord.new(content: chunk.pack('c*'))
      end, bytes.size]
    end

    # @param fdst_record [Dyck::PalmDBRecord]
    def write_fdst(fdst_record)
      io = StringIO.new
      io.binmode
      io.write([FDST_MAGIC, 12, @flow.size].pack(%(A#{FDST_MAGIC.bytesize}NN)))
      start = 0
      @flow.each do |f|
        end_ = start + f.bytesize
        io.write([start, end_].pack('NN'))
        start = end_
      end
      fdst_record.content = io.string
    end

    private

    # @param io [IO, StringIO]
    # @param fdst_index [Fixnum]
    # @param fdst_section_count [Fixnum]
    # @param image_index [Fixnum]
    def write_mobi_header(io, fdst_index, fdst_section_count, image_index, exth_size, full_name) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
      header_length = 264
      uid = 0
      io.write([MOBI_MAGIC, header_length, @mobi_type, @text_encoding, uid, @version]
                   .concat([MOBI_NOTSET] * 11)
                   .concat([16 + header_length + exth_size, full_name.size])
                   .concat([MOBI_NOTSET] * 3)
                   .concat([@version, image_index])
                   .concat([MOBI_NOTSET] * 4)
                   .concat([0x40]) # EXTH flags
                   .concat([MOBI_NOTSET] * 15)
                   .concat([fdst_index || 0, fdst_section_count])
                   .concat([MOBI_NOTSET] * 10)
                   .concat([0])
                   .concat([MOBI_NOTSET] * 9)
                   .pack(%(A#{MOBI_MAGIC.bytesize}N*)))
    end

    # @param io [IO, StringIO]
    # @param exth_records [Array<Dyck::ExthRecord>]
    def write_exth_header(io, exth_records)
      io.write(EXTH_MAGIC)

      exth_header_length = 12
      exth_records.each do |exth_record|
        exth_header_length += exth_record.data.bytesize + 8
      end
      io.write([exth_header_length, exth_records.size].pack('N*'))
      exth_records.each do |exth_record|
        io.write([exth_record.tag, exth_record.data.bytesize + 8, exth_record.data].pack('NNa*'))
      end
    end
  end

  # Represents a single Mobi file
  class Mobi # rubocop:disable Metrics/ClassLength
    TYPE_MAGIC = 'BOOK'.b
    CREATOR_MAGIC = 'MOBI'.b

    EOF_MAGIC = "\xe9\x8e\r\n".b
    BOUNDARY_MAGIC = 'BOUNDARY'.b

    JPEG_MAGIC = "\xff\xd8\xff".b
    GIF_MAGIC = "\x47\x49\x46\x38".b
    PNG_MAGIC = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a".b
    BMP_MAGIC = "\x42\x4d".b
    FONT_MAGIC = 'FONT'.b
    AUDIO_MAGIC = 'AUDI'.b
    VIDEO_MAGIC = 'VIDE'.b

    # @return [Dyck::MobiData]
    attr_accessor(:kf7)
    # @return [Dyck::MobiData]
    attr_accessor(:kf8)
    # @return [Array<Dyck::MobiResource>]
    attr_accessor(:resources)
    # @return [String]
    attr_accessor(:title)
    # @return [String]
    attr_accessor(:author)
    # @return [String]
    attr_accessor(:publisher)
    # @return [String]
    attr_accessor(:description)
    # @return [Array<String>]
    attr_accessor(:subjects)
    # @return [Time]
    attr_accessor(:publishing_date)
    # @return [String]
    attr_accessor(:copyright)

    # @param kf7 [Dyck::MobiData]
    # @param kf8 [Dyck::MobiData, nil]
    # @param resources [Array<Dyck::MobiResource>]
    # @param author [String]
    # @param publisher [String]
    # @param description [String]
    # @param subjects [Array<String>]
    # @param publishing_date [Time]
    # @param copyright [String]
    def initialize( # rubocop:disable Metrics/ParameterLists
      kf7: MobiData.new(version: 6),
      kf8: nil,
      resources: [],
      title: ''.b,
      author: ''.b,
      publisher: ''.b,
      description: ''.b,
      subjects: [],
      publishing_date: Time.now.round,
      copyright: ''.b
    )
      @kf7 = kf7
      @kf8 = kf8
      @resources = resources
      @title = title
      @author = author
      @publisher = publisher
      @description = description
      @subjects = subjects
      @publishing_date = publishing_date
      @copyright = copyright
    end

    class << self
      # @return [Dyck::Mobi]
      def read(filename_or_io)
        palmdb = PalmDB.read(filename_or_io)
        from_palmdb(palmdb)
      end

      # @param palmdb [Dyck::PalmDB]
      # @return [Dyck::Mobi]
      def from_palmdb(palmdb) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        raise ArgumentError, %(Unsupported type: #{palmdb.type}) if palmdb.type != TYPE_MAGIC
        raise ArgumentError, %(Unsupported creator: #{palmdb.type}) if palmdb.creator != CREATOR_MAGIC

        kf7, image_index, kf7_exth_records, kf7_full_name = if palmdb.records.empty?
                                                              [MobiData.new(version: 6), nil, [], ''.b]
                                                            else
                                                              MobiData.read(palmdb.records, 0)
                                                            end

        kf8_boundary = ExthRecord.find(ExthRecord::KF8_BOUNDARY, kf7_exth_records)
        kf8, _, kf8_exth_records, kf8_full_name = if kf8_boundary.nil?
                                                    [nil, nil, nil, nil]
                                                  else
                                                    MobiData.read(palmdb.records, kf8_boundary.data_uint32)
                                                  end

        exth_records = kf8_exth_records || kf7_exth_records || []
        resources = read_resources(palmdb.records, image_index)

        publishing_date = ExthRecord.find(ExthRecord::PUBLISHING_DATE, exth_records)&.data
        Mobi.new(
          kf7: kf7,
          kf8: kf8,
          resources: resources,
          author: ExthRecord.find(ExthRecord::AUTHOR, exth_records)&.data || ''.b,
          title: kf8_full_name || kf7_full_name || ''.b,
          publisher: ExthRecord.find(ExthRecord::PUBLISHER, exth_records)&.data || ''.b,
          description: ExthRecord.find(ExthRecord::DESCRIPTION, exth_records)&.data || ''.b,
          subjects: exth_records.select { |r| r.tag == ExthRecord::SUBJECT }.map(&:data),
          publishing_date: publishing_date.nil? ? Time.now : Time.iso8601(publishing_date),
          copyright: ExthRecord.find(ExthRecord::RIGHTS, exth_records)&.data || ''.b
        )
      end

      private

      # @param records [Array<Dyck::PalmDBRecord>]
      # @param image_index [Fixnum]
      # @return [Array<Dyck::MobiResource>]
      def read_resources(records, image_index) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        return [] if image_index.nil?

        result = []
        (image_index..records.size - 1).map do |index| # rubocop:disable Metrics/BlockLength
          content = records[index].content

          break if content == BOUNDARY_MAGIC
          break if content == EOF_MAGIC

          type = nil
          if content.start_with?(JPEG_MAGIC)
            type = :jpeg
          elsif content.start_with?(BMP_MAGIC)
            size = content[2..6]&.unpack1('V')
            type = :bmp if size == content.bytesize
          elsif content.start_with?(GIF_MAGIC)
            type = :gif
          elsif content.start_with?(FONT_MAGIC)
            # TODO: strip prefix
            type = :font
          elsif content.start_with?(PNG_MAGIC)
            type = :png
          elsif content.start_with?(AUDIO_MAGIC)
            offset = content[AUDIO_MAGIC.size..AUDIO_MAGIC.size + 4].unpack1('N')
            type = :audio
            content = content[offset..content.size - 1]
          elsif content.start_with?(VIDEO_MAGIC)
            offset = content[VIDEO_MAGIC.size..VIDEO_MAGIC.size + 4].unpack1('N')
            type = :video
            content = content[offset..content.size - 1]
          end
          next if type.nil?

          result << MobiResource.new(type, content)
        end
        result
      end
    end

    def write(filename_or_io)
      to_palmdb.write(filename_or_io)
    end

    # @return [Dyck::PalmDB]
    def to_palmdb # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      palmdb = PalmDB.new(type: TYPE_MAGIC, creator: CREATOR_MAGIC)
      palmdb.records << (kf7_header = PalmDBRecord.new)
      kf7_content_chunks, kf7_text_length = @kf7.content_chunks
      palmdb.records.concat(kf7_content_chunks)
      image_start = write_resources(palmdb.records)
      exth_records = [
        ExthRecord.new(tag: ExthRecord::AUTHOR, data: @author),
        ExthRecord.new(tag: ExthRecord::PUBLISHER, data: @publisher),
        ExthRecord.new(tag: ExthRecord::DESCRIPTION, data: @description),
        ExthRecord.new(tag: ExthRecord::PUBLISHING_DATE, data: @publishing_date.utc.iso8601),
        ExthRecord.new(tag: ExthRecord::RIGHTS, data: @copyright)
      ]
      exth_records += @subjects.map { |s| ExthRecord.new(tag: ExthRecord::SUBJECT, data: s) }

      if @kf8
        kf8_boundary = palmdb.records.size
        palmdb.records << (kf8_header = PalmDBRecord.new)
        kf8_content_chunks, kf8_text_length = @kf8.content_chunks
        palmdb.records.concat(kf8_content_chunks)
        fdst_index = palmdb.records.size - kf8_boundary
        palmdb.records << (fdst_record = PalmDBRecord.new)
        @kf8.write_fdst(fdst_record)
        @kf8.write(
          kf8_header,
          kf8_text_length,
          kf8_content_chunks.size,
          fdst_index,
          MobiData::MOBI_NOTSET,
          exth_records,
          @title
        )
        # Only KF7 needs this
        exth_records << ExthRecord.new(tag: ExthRecord::KF8_BOUNDARY, data: [kf8_boundary].pack('N'))
      end
      @kf7.write(kf7_header, kf7_text_length, kf7_content_chunks.size, 0, image_start, exth_records, @title)
      palmdb
    end

    private

    # @param records [Array<Dyck::PalmDBRecord>]
    # @return [Fixnum]
    def write_resources(records) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength:
      image_start = records.size
      records.concat(@resources.map do |resource|
        content = case resource.type
                  when :audio
                    AUDIO_MAGIC + [AUDIO_MAGIC.size + 4].pack('N') + resource.content
                  when :video
                    VIDEO_MAGIC + [VIDEO_MAGIC.size + 4].pack('N') + resource.content
                  else
                    resource.content
                  end
        PalmDBRecord.new(content: content)
      end)
      records << PalmDBRecord.new(content: BOUNDARY_MAGIC)
      image_start
    end
  end
end
