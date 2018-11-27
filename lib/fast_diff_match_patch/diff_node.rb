# frozen_string_literal: true

class FastDiffMatchPatch
  VALID_OPERATIONS = [:INSERT, :DELETE, :EQUAL].to_set.freeze
  OPERATOR_TO_CHAR = { INSERT: "+", DELETE: "-", EQUAL: " " }.freeze
  ENCODE_REGEX     = /[^0-9A-Za-z_.;!~*'(),\/?:@&=+$\#-]/.freeze

  DiffNode = Struct.new(:operation, :text) do
    def initialize(operation, text)
      operation       = operation.to_s.upcase.to_sym unless VALID_OPERATIONS.member?(operation)
      self.operation  = operation
      self.text       = text
    end

    VALID_OPERATIONS.each do |opt|
      method = opt.to_s.downcase
      define_method("is_#{method}?") do
        operation == opt
      end

      define_method("to_#{method}!") do
        self.operation = opt
      end
    end

    alias_method :text1_change?, :is_delete?
    alias_method :text2_change?, :is_insert?
  end

  TempPatch = Struct.new(:diffs, :start1, :start2, :length1, :length2) do
    def initialize(diffs = [], start1 = 0, start2 = 0, length1 = 0, length2 = 0)
      self.diffs   = diffs
      self.start1  = start1
      self.start2  = start2
      self.length1 = length1
      self.length2 = length2
    end

    # Emulate GNU diff's format
    # Header: @@ -382,8 +481,9 @@
    # Indices are printed as 1-based, not 0-based.
    def to_s
      coords1 = get_coords(length1, start1)
      coords2 = get_coords(length2, start2)

      text = ["@@ -", coords1, " +", coords2, " @@\n"].join

      # Encode the body of the patch with %xx notation.
      text + diffs.map do |diff|
        [OPERATOR_TO_CHAR[diff.operation], URI.encode(diff.text, ENCODE_REGEX), "\n"].join
      end.join.gsub("%20", " ")
    end

    def get_coords(length, start)
      if length.zero?
        start.to_s + ",0"
      elsif length == 1
        (start + 1).to_s
      else
        (start + 1).to_s + "," + length.to_s
      end
    end
  end
end
