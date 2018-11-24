# frozen_string_literal: true

require "spec_helper"

RSpec.describe FastDiffMatchPatch do
  describe "#match_bitap" do
    let(:threshold)      { 0.5 }
    let(:match_distance) { 100 }
    let(:dmp) { described_class.new(match_distance: match_distance, match_threshold: threshold) }

    context "when there's exact matching" do
      it { expect(dmp.match_bitap("abcdefghijk", "fgh", 5)).to eq(5) }
      it { expect(dmp.match_bitap("abcdefghijk", "fgh", 0)).to eq(5) }
    end

    context "when there's fuzzy search matching" do
      it { expect(dmp.match_bitap("abcdefghijk", "efxhi", 0)).to eq(4) }
      it { expect(dmp.match_bitap("abcdefghijk", "cdefxyhijk", 5)).to eq(2) }
      it { expect(dmp.match_bitap("abcdefghijk", "bxy", 1)).to eq(-1) }
    end

    context "when there's an overflow" do
      it { expect(dmp.match_bitap("123456789xx0", "3456789x0", 2)).to eq(2) }
    end

    describe "Threshold" do
      context "when its 0.4" do
        let(:threshold) { 0.4 }
        it { expect(dmp.match_bitap("abcdefghijk", "efxyhi", 1)).to eq(4) }
      end

      context "when its 0.3" do
        let(:threshold) { 0.3 }
        it { expect(dmp.match_bitap("abcdefghijk", "efxyhi", 1)).to eq(-1) }
      end

      context "when its 0.0" do
        let(:threshold) { 0.0 }
        it { expect(dmp.match_bitap("abcdefghijk", "bcdef", 1)).to eq(1) }
      end
    end

    describe "Match Distance" do
      context "when its 10 and strict" do
        let(:match_distance) { 10 }
        it { expect(dmp.match_bitap("abcdefghijklmnopqrstuvwxyz", "abcdefg", 24)).to eq(-1) }
        it { expect(dmp.match_bitap("abcdefghijklmnopqrstuvwxyz", "abcdxxefg", 1)).to eq(0) }
      end

      context "when its 1000 and loose" do
        let(:match_distance) { 1000 }
        it { expect(dmp.match_bitap("abcdefghijklmnopqrstuvwxyz", "abcdefg", 24)).to eq(0) }
      end
    end
  end

  describe "#match_main" do
    let(:dmp) { described_class.new(match_distance: 1000, match_threshold: 0.5) }

    context "when full match occurs" do
      it { expect(dmp.match_main("abcdef", "abcdef", 1000)).to eq(0) }
      it { expect(dmp.match_main("", "abcdef", 1)).to eq(-1) }
      it { expect(dmp.match_main("abcdef", "", 3)).to eq(3) }
      it { expect(dmp.match_main("abcdef", "de", 3)).to eq(3) }
    end

    context "when the match is beyond end" do
      it { expect(dmp.match_main("abcdef", "defy", 4)).to eq(3) }
    end

    context "when pattern is oversize" do
      it { expect(dmp.match_main("abcdef", "abcdefy", 0)).to eq(0) }
    end

    context "when the match is complex" do
      it do
        text    = "I am the very model of a modern major general."
        pattern = " that berry "
        expect(dmp.match_main(text, pattern, 5)).to eq(4)
      end
    end

    context "when any argument is nil" do
      it "should raise an exception" do
        expect { dmp.match_main(nil, nil, 0) }.to raise_error(ArgumentError)
      end
    end
  end
end
