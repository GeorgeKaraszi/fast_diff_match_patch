# frozen_string_literal: true

module FastDiffMatchPatch
  class Diff
    VALID_OPERATIONS = [:INSERT, :DELETE, :EQUAL].to_set.freeze
    Node = Struct.new(:operation, :text) do
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
  end
end
