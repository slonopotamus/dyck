# frozen_string_literal: true

require 'dyck/index'
require 'dyck/palmdb'
require 'dyck/util'
require 'time'
require 'zlib'

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
    CREATOR_SOFTWARE = 204
    CREATOR_SOFTWARE_MAJOR = 205
    CREATOR_SOFTWARE_MINOR = 206
    CREATOR_SOFTWARE_BUILD = 207
    CREATOR_SOFTWARE_REVISION = 535

    # @return [Integer]
    attr_reader(:tag)
    # @return [String]
    attr_reader(:data)

    def initialize(tag: 0, data: ''.b)
      @tag = tag
      @data = data
    end

    class << self
      # @param tag [Integer]
      # @param records [Array<Dyck::ExthRecord>]
      def find(tag, records)
        records.detect { |record| record.tag == tag }
      end
    end
  end

  MobiHeader = Struct.new(
    :version,
    :mobi_type,
    :text_encoding,
    :extra_flags,
    :fdst_index,
    :fdst_section_count,
    :image_index,
    :full_name_offset,
    :full_name_length,
    :frag_index,
    :skel_index
  )

  # A single MOBI6/KF8 data
  class MobiData # rubocop:disable Metrics/ClassLength
    NO_COMPRESSION = 1
    PALMDOC_COMPRESSION = 2
    HUFF_COMPRESSION = 17_480
    SUPPORTED_COMPRESSIONS = [NO_COMPRESSION].freeze

    NO_ENCRYPTION = 0
    OLD_ENCRYPTION = 1
    MOBI_ENCRYPTION = 2
    SUPPORTED_ENCRYPTIONS = [NO_ENCRYPTION].freeze

    MOBI_MAGIC = 'MOBI'.b
    EXTH_MAGIC = 'EXTH'.b

    FDST_MAGIC = 'FDST'.b
    FDST_HEADER = %(A#{FDST_MAGIC.bytesize}NN)

    MAX_RECORD_SIZE = 4096

    INDX_TAG_SKEL_COUNT = IndexTagKey.new(tag_id: 1, tag_index: 0)
    INDX_TAG_SKEL_POSITION = IndexTagKey.new(tag_id: 6, tag_index: 0)
    INDX_TAG_SKEL_LENGTH = IndexTagKey.new(tag_id: 6, tag_index: 1)

    INDX_TAG_FRAG_POSITION = IndexTagKey.new(tag_id: 6, tag_index: 0)
    INDX_TAG_FRAG_LENGTH = IndexTagKey.new(tag_id: 6, tag_index: 1)

    # @return Integer
    attr_accessor(:compression)
    # @return Integer
    attr_accessor(:encryption)
    # @return Integer
    attr_accessor(:mobi_type)
    # @return Integer
    attr_accessor(:text_encoding)
    # @return Integer
    attr_accessor(:version)
    # @return [Array<String>]
    attr_accessor(:flow)
    # @return [Array<String>]
    attr_accessor(:parts)

    def initialize( # rubocop:disable Metrics/ParameterLists
      compression: NO_COMPRESSION,
      encryption: NO_ENCRYPTION,
      mobi_type: 2,
      text_encoding: TEXT_ENCODING_UTF8,
      flow: [],
      parts: []
    )
      @compression = compression
      @encryption = encryption
      @mobi_type = mobi_type
      @text_encoding = text_encoding
      @flow = flow
      @parts = parts
    end

    class << self
      # @param records [Array<Dyck::PalmDBRecord>]
      def read(records) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        io = StringIO.new(records[0].content)
        result = MobiData.new
        result.compression, _zero, _text_length, text_record_count, _text_record_size, result.encryption, _unknown1 =
          io.read(16).unpack('nnNn*')
        unless SUPPORTED_COMPRESSIONS.include? result.compression
          raise ArgumentError, %(Unsupported MOBI compression: #{result.compression})
        end
        unless SUPPORTED_ENCRYPTIONS.include? result.encryption
          raise ArgumentError, %(Unsupported MOBI encryption: #{result.encryption})
        end

        mobi_header = read_mobi_header(io)
        result.mobi_type = mobi_header.mobi_type
        result.text_encoding = mobi_header.text_encoding
        exth_records = read_exth_header(io)

        if set?(mobi_header.full_name_offset)
          io.seek(mobi_header.full_name_offset)
          full_name = io.read(mobi_header.full_name_length)
        else
          full_name = ''.b
        end

        content = read_content(text_record_count, records[1..-1], mobi_header.extra_flags)
        fdst = read_fdst(mobi_header.fdst_index, records, mobi_header.fdst_section_count)
        result.flow = reconstruct_flow(content, fdst)
        skel = MobiData.set?(mobi_header.skel_index) ? Index.read(records[mobi_header.skel_index..-1], 'skel') : nil
        frag = MobiData.set?(mobi_header.frag_index) ? Index.read(records[mobi_header.frag_index..-1], 'frag') : nil
        result.parts = reconstruct_parts(result.flow, skel, frag)
        [result, mobi_header.version, mobi_header.image_index, exth_records, full_name]
      end

      # @param field [Integer, nil]
      # @return [Boolean]
      def set?(field)
        !field.nil? && field != MOBI_NOTSET
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

      # @param flow [Array<String>]
      # @param skel [Dyck::Index, nil]
      # @param frag [Dyck::Index, nil]
      def reconstruct_parts(flow, skel, frag) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        return [] if flow.empty?

        rawml = flow.shift
        return [rawml] if skel.nil?

        frag_offset = 0
        insert_offset = 0
        io = StringIO.new(rawml)
        skel.entries.map do |skel_entry|
          skel_position = skel_entry.tag_value(INDX_TAG_SKEL_POSITION)
          skel_length = skel_entry.tag_value(INDX_TAG_SKEL_LENGTH)
          fragments_count = skel_entry.tag_value(INDX_TAG_SKEL_COUNT)

          io.seek(skel_position, IO::SEEK_SET)
          part = io.read(skel_length)

          if fragments_count.positive?
            raise ArgumentError, 'File has fragments but no frag index' if frag.nil?

            frag.entries[frag_offset..frag_offset + fragments_count - 1].each do |f|
              insert_pos = Integer(f.label, 10)
              insert_pos -= insert_offset
              frag_length = f.tag_value(INDX_TAG_FRAG_LENGTH)
              part.insert(insert_pos, io.read(frag_length))
            end
          end
          frag_offset += fragments_count
          insert_offset += part.size
          part
        end
      end

      # @param count [Integer]
      # @param records [Array<PalmDBRecord>]
      # @return [String]
      def read_content(count, records, extra_flags)
        content = ''.b
        (0..count - 1).each do |idx|
          record_content = records[idx].content
          extra_size = get_record_extra_size(record_content, extra_flags)
          content += record_content[0..record_content.bytesize - extra_size - 1]
        end
        content
      end

      # @param fdst_index [Integer, nil]
      # @param records [Array<Dyck::PalmDBRecord>]
      # @return [Array<Range>]
      def read_fdst(fdst_index, records, fdst_section_count)
        return nil if fdst_index.nil? || fdst_section_count.nil? || fdst_section_count <= 1

        fdst_record = records[fdst_index]
        io = StringIO.new(fdst_record.content)
        magic, _data_offset, _section_count = io.read(12).unpack(FDST_HEADER)
        raise ArgumentError, %(Unsupported FDST magic: #{magic}) if magic != FDST_MAGIC

        fdst_section_count.times.map do |_|
          start, end_ = io.read(8).unpack('NN')
          (start..end_)
        end
      end

      # @param data [String]
      # @param extra_flags [Integer]
      # @return [Integer]
      def get_record_extra_size(data, extra_flags) # rubocop:disable Metrics/MethodLength
        num = 0
        flags = extra_flags >> 1
        while flags != 0
          if (flags & 1) != 0
            val, _consumed = Dyck.decode_varlen_dec(data, data.size - num - 1)
            num += val
          end
          flags >>= 1
        end
        num += (data[data.size - num - 1].unpack1('C') & 0x3) + 1 if (extra_flags & 1) != 0
        num
      end

      # @param io [IO, StringIO]
      # @return [Dyck::MobiHeader]
      def read_mobi_header(io) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        magic = io.read(4)
        raise ArgumentError, %(Unsupported MOBI magic: #{magic}) if magic != MOBI_MAGIC

        mobi_header_length = io.read(4).unpack1('N')
        mobi_header = StringIO.new(io.read(mobi_header_length - 8))
        result = MobiHeader.new
        result.mobi_type, result.text_encoding, _uid, result.version, = mobi_header.read(15 * 4).unpack('N*')

        unless SUPPORTED_TEXT_ENCODINGS.include?(result.text_encoding)
          raise ArgumentError, %(Unsupported text encoding: #{result.text_encoding})
        end

        # there are more fields here
        result.full_name_offset, result.full_name_length, = mobi_header.read(5 * 4)&.unpack('N*')
        # there are more fields here
        _min_version, result.image_index, = mobi_header.read(22 * 4)&.unpack('N*')
        # there are more fields here
        if result.version >= 8
          result.fdst_index = mobi_header.read(4)&.unpack1('N')
        else
          # Assume that last_text_index is fdst_index for MOBI6
          _, result.fdst_index = mobi_header.read(4)&.unpack('nn')
        end
        result.fdst_section_count = mobi_header.read(4)&.unpack1('N')
        # there are more fields here
        mobi_header.seek(10 * 4 + 2, IO::SEEK_CUR)
        result.extra_flags = mobi_header.read(2)&.unpack1('n') || 0
        # there are more fields here
        mobi_header.seek(4, IO::SEEK_CUR)
        if result.version >= 8
          result.frag_index, result.skel_index = mobi_header.read(8).unpack('N*')
        else
          result.frag_index = result.skel_index = MOBI_NOTSET
        end
        # there are more fields here

        result
      end

      # @param io [IO, StringIO]
      # @return [Array<Dyck::ExthRecord]
      def read_exth_header(io)
        exth = io.read(4)
        raise ArgumentError, %(Unsupported EXTH magic: #{exth}) if exth != EXTH_MAGIC

        exth_header_length, exth_record_count = io.read(8).unpack('N*')
        exth_header = StringIO.new(io.read(exth_header_length - 12))
        exth_record_count.times.map do |_|
          tag, data_len = exth_header.read(8).unpack('N*')
          data = exth_header.read(data_len - 8)
          ExthRecord.new(tag: tag, data: data)
        end
      end
    end

    # @param version [Number]
    # @param header_record [Dyck::PalmDBRecord]
    # @param text_length [Integer]
    # @param text_record_count [Integer]
    # @param fdst_index [Integer]
    # @param fcis_index [Integer]
    # @param flis_index [Integer]
    # @param image_index [Integer]
    # @param exth_records [Array<Dyck::ExthRecord>]
    # @param flow [Array<String>]
    # @param skel_index [Integer]
    def write( # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
      version,
      header_record,
      text_length,
      text_record_count,
      fdst_index,
      fcis_index,
      flis_index,
      image_index,
      exth_records,
      full_name,
      flow,
      skel_index = MOBI_NOTSET
    )
      io = StringIO.new
      io.binmode
      io.write([compression, 0, text_length, text_record_count, MAX_RECORD_SIZE, encryption, 0].pack('nnNn*'))

      exth_buf = StringIO.new
      exth_buf.binmode
      write_exth_header(exth_buf, exth_records)
      write_mobi_header(
        version,
        io,
        fdst_index,
        flow.size,
        fcis_index,
        flis_index,
        image_index,
        exth_buf.size,
        full_name,
        skel_index
      )
      io.write(exth_buf.string)
      io.write(full_name)
      io.write("\0")

      header_record.content = io.string
    end

    # @param flow [Array<String>]
    def content_chunks(flow)
      bytes = flow.join.bytes
      [bytes.each_slice(MobiData::MAX_RECORD_SIZE).map do |chunk|
        PalmDBRecord.new(content: chunk.pack('c*'))
      end, bytes.size]
    end

    # @param fdst_record [Dyck::PalmDBRecord]
    # @return [void]
    def write_fdst(fdst_record, flow)
      io = StringIO.new
      io.binmode
      io.write([FDST_MAGIC, 12, flow.size].pack(%(A#{FDST_MAGIC.bytesize}NN)))
      start = 0
      flow.each do |f|
        end_ = start + f.bytesize
        io.write([start, end_].pack('NN'))
        start = end_
      end
      fdst_record.content = io.string
    end

    private

    # @param version [Number]
    # @param io [IO, StringIO]
    # @param fdst_index [Integer]
    # @param fdst_section_count [Integer]
    # @param fcis_index [Integer]
    # @param flis_index [Integer]
    # @param image_index [Integer]
    # @param skel_index [Integer]
    # @return [void]
    def write_mobi_header( # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
      version,
      io,
      fdst_index,
      fdst_section_count,
      fcis_index,
      flis_index,
      image_index,
      exth_size,
      full_name,
      skel_index
    )
      header_size = 264
      uid = 0
      header = [MOBI_MAGIC, header_size, @mobi_type, @text_encoding, uid, version]
      header << MOBI_NOTSET # orth index
      header << MOBI_NOTSET # infl index
      header << MOBI_NOTSET # names index
      header << MOBI_NOTSET # keys index
      header += [MOBI_NOTSET] * 6 # unknown indexes
      header << MOBI_NOTSET # first record number (starting with 0) that's not the book's text
      header += [16 + header_size + exth_size, full_name.size]
      header += [0] * 3
      header += [version, image_index]
      header += [0] * 4
      header += [0x40] # EXTH flags
      header += [0] * 4
      header << MOBI_NOTSET # unknown index
      header << MOBI_NOTSET # drm index
      header += [0] * 9
      header += [fdst_index, fdst_section_count, fcis_index]
      header << 1 # FCIS record count
      header << flis_index
      header << 1 # FLIS record count
      header += [0] * 2
      header << MOBI_NOTSET # srcs index
      header += [0] * 4
      header << MOBI_NOTSET # NCX index
      header << MOBI_NOTSET # FRAG index
      header << skel_index
      header << MOBI_NOTSET # DATP index
      header << MOBI_NOTSET # Guide index
      header += [MOBI_NOTSET, 0, MOBI_NOTSET, 0] # unknown
      header_data = header.pack(%(A#{MOBI_MAGIC.bytesize}N*))
      raise %(Internal error: #{header_size} != #{header_data.size}) if header_size != header_data.size

      io.write(header_data)
    end

    # @param io [IO, StringIO]
    # @param exth_records [Array<Dyck::ExthRecord>]
    # @return [void]
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
    attr_accessor(:mobi6)
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

    # @param mobi6 [Dyck::MobiData, nil]
    # @param kf8 [Dyck::MobiData, nil]
    # @param resources [Array<Dyck::MobiResource>]
    # @param author [String]
    # @param publisher [String]
    # @param description [String]
    # @param subjects [Array<String>]
    # @param publishing_date [Time]
    # @param copyright [String]
    def initialize( # rubocop:disable Metrics/ParameterLists
      mobi6: nil,
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
      @mobi6 = mobi6
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
        raise ArgumentError, %(Unsupported PalmBD type: #{palmdb.type}) if palmdb.type != TYPE_MAGIC
        raise ArgumentError, %(Unsupported PalmBD creator: #{palmdb.type}) if palmdb.creator != CREATOR_MAGIC

        mobi6, mobi6_version, image_index, exth_records, full_name = if palmdb.records.empty?
                                                                       [MobiData.new, 8, nil, [], ''.b]
                                                                     else
                                                                       MobiData.read(palmdb.records)
                                                                     end

        if mobi6_version >= 8
          # KF8-only file
          kf8 = mobi6
          mobi6 = nil
        else
          kf8_boundary = ExthRecord.find(ExthRecord::KF8_BOUNDARY, exth_records)
          if kf8_boundary.nil?
            # MOBI6-only file
            kf8 = nil
          else
            # MOBI6 + KF8 hybrid file
            kf8_offset = kf8_boundary.data.unpack1('N')
            kf8, _, _, exth_records, = MobiData.read(palmdb.records[kf8_offset..-1])
          end
        end

        resources = image_index.nil? ? [] : read_resources(palmdb.records[image_index..-1])

        publishing_date = ExthRecord.find(ExthRecord::PUBLISHING_DATE, exth_records)&.data
        if publishing_date.nil? then
          publishing_timestamp = Time.now
        else
          begin
            # Try the spec-compliant strict parse first.
            publishing_timestamp = Time.iso8601(publishing_date)
          rescue ArgumentError  # Fall back to fuzzy parse.
            # Check for year on its own.
            if publishing_date =~ /^\d\d\d\d$/ then
              publishing_timestamp = Time.parse("#{publishing_date}-01-01")
            else
              publishing_timestamp = Time.parse(publishing_date)
            end
          end
        end

        Mobi.new(
          mobi6: mobi6,
          kf8: kf8,
          resources: resources,
          author: ExthRecord.find(ExthRecord::AUTHOR, exth_records)&.data || ''.b,
          title: full_name || ''.b,
          publisher: ExthRecord.find(ExthRecord::PUBLISHER, exth_records)&.data || ''.b,
          description: ExthRecord.find(ExthRecord::DESCRIPTION, exth_records)&.data || ''.b,
          subjects: exth_records.select { |r| r.tag == ExthRecord::SUBJECT }.map(&:data),
          publishing_date: publishing_timestamp,
          copyright: ExthRecord.find(ExthRecord::RIGHTS, exth_records)&.data || ''.b
        )
      end

      private

      # @param records [Array<Dyck::PalmDBRecord>]
      # @return [Array<Dyck::MobiResource>]
      def read_resources(records) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        result = []
        (0..records.size - 1).map do |index| # rubocop:disable Metrics/BlockLength
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
            type = :font
            content = read_font_resource(content)
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
          else
            type = :unknown
          end

          result << MobiResource.new(type, content)
        end
        result
      end

      # @param data [String]
      # @return [String]
      def read_font_resource(data) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        decoded_size, flags, data_offset, xor_key_len, xor_key_offset = data[AUDIO_MAGIC.size..-1].unpack('N5')

        font_data = data[data_offset..-1]

        unless (flags & 0b10).zero?
          key = data[xor_key_offset..xor_key_offset + xor_key_len]
          extent = [font_data.bytesize, 1040].min

          (0..extent - 1).each do |n|
            font_data[n] ^= key[n % xor_key_len] # XOR of buf and key
          end
        end

        font_data = Zlib::Inflate.inflate(font_data) unless (flags & 0b1).zero?
        raise ArgumentError, 'Uncompressed font size mismatch' if font_data.bytesize != decoded_size

        font_data
      end
    end

    def write(filename_or_io)
      to_palmdb.write(filename_or_io)
    end

    # @return [Dyck::PalmDB]
    def to_palmdb # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      palmdb = PalmDB.new(type: TYPE_MAGIC, creator: CREATOR_MAGIC)

      image_index = MOBI_NOTSET
      unless @mobi6.nil?
        palmdb.records << (mobi6_header = PalmDBRecord.new)
        mobi6_flow = [@mobi6.parts.empty? ? '' : @mobi6.parts.join('\n')] + @mobi6.flow
        mobi6_content_chunks, mobi6_text_length = @mobi6.content_chunks(mobi6_flow)
        palmdb.records.concat(mobi6_content_chunks)
        image_index = write_resources(palmdb.records)
      end

      exth_records = [
        ExthRecord.new(tag: ExthRecord::AUTHOR, data: @author),
        ExthRecord.new(tag: ExthRecord::PUBLISHER, data: @publisher),
        ExthRecord.new(tag: ExthRecord::DESCRIPTION, data: @description),
        ExthRecord.new(tag: ExthRecord::PUBLISHING_DATE, data: @publishing_date.utc.iso8601),
        ExthRecord.new(tag: ExthRecord::RIGHTS, data: @copyright),
        ExthRecord.new(tag: ExthRecord::CREATOR_SOFTWARE, data: [201].pack('N')),
        ExthRecord.new(tag: ExthRecord::CREATOR_SOFTWARE_MAJOR, data: [2].pack('N')),
        ExthRecord.new(tag: ExthRecord::CREATOR_SOFTWARE_MINOR, data: [9].pack('N')),
        ExthRecord.new(tag: ExthRecord::CREATOR_SOFTWARE_BUILD, data: [0].pack('N')),
        ExthRecord.new(
          tag: ExthRecord::CREATOR_SOFTWARE_REVISION,
          data: %(Dyck #{Dyck::VERSION} [https://github.com/slonopotamus/dyck])
        )
      ]
      exth_records += @subjects.map { |s| ExthRecord.new(tag: ExthRecord::SUBJECT, data: s) }

      unless @kf8.nil?
        kf8_boundary = palmdb.records.size
        palmdb.records << (kf8_header = PalmDBRecord.new)
        kf8_flow = [@kf8.parts.empty? ? '' : @kf8.parts.join('\n')] + @kf8.flow
        kf8_content_chunks, kf8_text_length = @kf8.content_chunks(kf8_flow)
        palmdb.records.concat(kf8_content_chunks)
        image_index = write_resources(palmdb.records) if image_index == MOBI_NOTSET

        fdst_index = palmdb.records.size - kf8_boundary
        palmdb.records << (fdst_record = PalmDBRecord.new)
        @kf8.write_fdst(fdst_record, kf8_flow)

        skel = Index.new('skel')

        skel_offset = 0
        @kf8.parts.each_with_index do |part, part_index|
          skel_label = %(SKEL#{part_index.to_s.rjust(10, '0').b})
          skel.entries << (skel_entry = IndexEntry.new(label: skel_label))
          skel_entry.set_tag_value(MobiData::INDX_TAG_SKEL_POSITION, skel_offset)
          skel_entry.set_tag_value(MobiData::INDX_TAG_SKEL_LENGTH, part.size)
          skel_entry.set_tag_value(MobiData::INDX_TAG_SKEL_COUNT, 0)
          skel_offset += part.size
        end

        skel_index = palmdb.records.size - kf8_boundary
        palmdb.records.concat(skel.write)

        fcis_index = palmdb.records.size - kf8_boundary
        palmdb.records << write_fcis(kf8_text_length)

        flis_index = palmdb.records.size - kf8_boundary
        palmdb.records << write_flis
        palmdb.records << (_eof_record = PalmDBRecord.new(content: "\xe9\x8e\r\n".b))

        @kf8.write(
          8,
          kf8_header,
          kf8_text_length,
          kf8_content_chunks.size,
          fdst_index,
          fcis_index,
          flis_index,
          image_index,
          exth_records,
          @title,
          kf8_flow,
          skel_index
        )
        # Only MOBI6 needs this
        exth_records << ExthRecord.new(tag: ExthRecord::KF8_BOUNDARY, data: [kf8_boundary].pack('N'))
      end

      @mobi6&.write(
        6,
        mobi6_header,
        mobi6_text_length,
        mobi6_content_chunks.size,
        MOBI_NOTSET,
        MOBI_NOTSET,
        MOBI_NOTSET,
        image_index,
        exth_records,
        @title,
        mobi6_flow
      )

      palmdb
    end

    private

    def write_fcis(text_length)
      fcis = "FCIS\x00\x00\x00\x14\x00\x00\x00\x10\x00\x00\x00\x02\x00\x00\x00\x00".b
      fcis += [text_length].pack('N')
      fcis += "\x00\x00\x00\x00\x00\x00\x00\x28\x00\x00\x00\x00\x00\x00\x00".b
      fcis += "\x28\x00\x00\x00\x08\x00\x01\x00\x01\x00\x00\x00\x00".b
      PalmDBRecord.new(content: fcis)
    end

    def write_flis
      flis = "FLIS\0\0\0\x08\0\x41\0\0\0\0\0\0\xff\xff\xff\xff\0\x01\0\x03\0\0\0\x03\0\0\0\x01".b + "\xff".b * 4
      PalmDBRecord.new(content: flis)
    end

    # @param records [Array<Dyck::PalmDBRecord>]
    # @return [Integer]
    def write_resources(records) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength:
      image_index = records.size
      records.concat(@resources.map do |resource|
        content = case resource.type
                  when :audio
                    AUDIO_MAGIC + [AUDIO_MAGIC.size + 4].pack('N') + resource.content
                  when :video
                    VIDEO_MAGIC + [VIDEO_MAGIC.size + 4].pack('N') + resource.content
                  when :font
                    write_font_resource(resource.content)
                  else
                    resource.content
                  end
        PalmDBRecord.new(content: content)
      end)
      records << PalmDBRecord.new(content: BOUNDARY_MAGIC)
      image_index
    end

    # @param data [String]
    # @param compress [Boolean]
    # @return [String]
    def write_font_resource(data, compress: true)
      flags = 0
      decoded_size = data.bytesize

      if compress
        flags |= 0b1
        data = Zlib::Deflate.deflate(data, Zlib::BEST_COMPRESSION)
      end

      # no obfuscation support for now
      xor_key = ''.b
      xor_key_offset = FONT_MAGIC.bytesize + 4 * 5
      data_offset = xor_key_offset + xor_key.bytesize

      FONT_MAGIC + [decoded_size, flags, data_offset, xor_key.bytesize, xor_key_offset].pack('N*') + data
    end
  end
end
