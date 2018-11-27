# frozen_string_literal: true

require "spec_helper"

RSpec.describe FastDiffMatchPatch do
  let(:dmp)   { FastDiffMatchPatch.new }
  let(:text1) { "The quick brown fox jumps over the lazy dog." }
  let(:text2) { "That quick brown fox jumped over a lazy dog." }

  describe "TempPatch" do
    let(:patch) { FastDiffMatchPatch::TempPatch.new([], 20, 21, 18, 17) }

    describe "#to_s" do
      before do
        patch.diffs.push(
          new_equal_node("jump"),
          new_delete_node("s"),
          new_insert_node("ed"),
          new_equal_node(" over "),
          new_delete_node("the"),
          new_insert_node("a"),
          new_equal_node("\nlaz")
        )
      end

      it { expect(patch.to_s).to eq("@@ -21,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n %0Alaz\n") }
    end
  end

  describe "#patch_from_text" do
    context "when text is empty" do
      it { expect(dmp.patch_from_text("")).to eq([]) }
    end

    context "when valid input text is provided" do
      it "Decodes the input text" do
        [
          "@@ -21,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n %0Alaz\n",
          "@@ -1 +1 @@\n-a\n+b\n",
          "@@ -1 +1 @@\n-a\n+b\n",
          "@@ -0,0 +1,3 @@\n+abc\n"
        ].each do |strp|
          expect(dmp.patch_from_text(strp).first.to_s).to eq(strp)
        end
      end
    end
  end

  describe "#patch_to_text" do
    context "when valid input diffs are provided" do
      it "Encodes the diffs found" do
        [
          "@@ -21,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n  laz\n",
          "@@ -1,9 +1,9 @@\n-f\n+F\n oo+fooba\n@@ -7,9 +7,9 @@\n obar\n-,\n+.\n  tes\n"
        ].each do |strp|
          pft = dmp.patch_from_text(strp)
          expect(dmp.patch_to_text(pft)).to eq(strp)
        end
      end
    end
  end

  describe "#patch_add_context" do
    before do
      dmp.patch_margin = 4
    end

    context "when theirs enough context to complete" do
      let(:patch_text)   { dmp.patch_from_text("@@ -21,4 +21,10 @@\n-jump\n+somersault\n").first }
      before { dmp.patch_add_context(patch_text, "The quick brown fox jumps over the lazy dog.") }

      it { expect(patch_text.to_s).to eq("@@ -17,12 +17,18 @@\n fox \n-jump\n+somersault\n s ov\n") }
    end

    context "when theres not enough trailing context" do
      let(:patch_text) { dmp.patch_from_text("@@ -21,4 +21,10 @@\n-jump\n+somersault\n").first }
      before { dmp.patch_add_context(patch_text, "The quick brown fox jumps.") }

      it { expect(patch_text.to_s).to eq("@@ -17,10 +17,16 @@\n fox \n-jump\n+somersault\n s.\n") }
    end

    context "when there's not enough leading context" do
      let(:patch_text) { dmp.patch_from_text("@@ -3 +3,2 @@\n-e\n+at\n").first }
      before { dmp.patch_add_context(patch_text, "The quick brown fox jumps.") }

      it { expect(patch_text.to_s).to eq("@@ -1,7 +1,8 @@\n Th\n-e\n+at\n  qui\n") }
    end

    context "when there's not enough leading context (abiguity)" do
      let(:patch_text) { dmp.patch_from_text("@@ -3 +3,2 @@\n-e\n+at\n").first }
      before { dmp.patch_add_context(patch_text, "The quick brown fox jumps.  The quick brown fox crashes.") }

      it { expect(patch_text.to_s).to eq("@@ -1,27 +1,28 @@\n Th\n-e\n+at\n  quick brown fox jumps. \n") }
    end
  end

  describe "#patch_make" do
    context "when providing null instances" do
      let(:patch) { dmp.patch_make("", "") }
      it { expect(dmp.patch_to_text(patch)).to eq("") }
      it { expect { dmp.patch_make(nil) }.to raise_error(ArgumentError) }
    end

    context "when providing two strings" do
      # "@@ -1,7 +1,6 @@\n-at\n+e\n at qu\n@@ -1,14 +1,15 @@\n-ed\n+s\n  over \n-a\n+the\n  brow\n"
      # "@@ -1,8 +1,7 @@\n-at\n+e\n at qui\n@@ -1,15 +1,16 @@\n-ed\n+s\n  over \n-a\n+the\n  brown\n"

      it "makes a patch from text2 => text1" do
        expected_patch = "@@ -1,8 +1,7 @@\n Th\n-at\n+e\n  qui\n@@ -21,17 +21,18 " \
                         "@@\n jump\n-ed\n+s\n  over \n-a\n+the\n  laz\n"

        patches = dmp.patch_make(text2, text1)
        expect(dmp.patch_to_text(patches)).to eq(expected_patch)
      end

      it "makes a patch from text1 => text2" do
        expected_patch = "@@ -1,11 +1,12 @@\n Th\n-e\n+at\n  quick b\n@@ -22,18"\
                         " +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n  laz\n"

        patches = dmp.patch_make(text1, text2)
        expect(dmp.patch_to_text(patches)).to eq(expected_patch)
      end
    end

    context "when providing diffs" do
      let(:diffs) { dmp.diff_main(text1, text2, false) }
      let(:expected_patch) do
        "@@ -1,11 +1,12 @@\n Th\n-e\n+at\n  quick b\n@@ -22,18"\
        " +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n  laz\n"
      end

      it "makes a patch from just diffs" do
        patches = dmp.patch_make(diffs)
        expect(dmp.patch_to_text(patches)).to eq(expected_patch)
      end

      it "makes a patch from text1 & diffs" do
        patches = dmp.patch_make(text1, diffs)
        expect(dmp.patch_to_text(patches)).to eq(expected_patch)
      end
    end

    context "when it encodes characters" do
      let(:patches) { dmp.patch_make('`1234567890-=[]\\;\',./', '~!@#$%^&*()_+{}|:"<>?') }
      let(:expected_patch) do
        "@@ -1,21 +1,21 @@\n-%601234567890-=%5B%5D%5C;\',./\n+~!"\
        "@\#$%25%5E&*()_+%7B%7D%7C:%22%3C%3E?\n"
      end

      it { expect(dmp.patch_to_text(patches)).to eq(expected_patch) }
    end

    context "when it decodes characters" do
      let(:diffs) { [new_delete_node('`1234567890-=[]\\;\',./'), new_insert_node('~!@#$%^&*()_+{}|:"<>?')] }
      let(:patches) { dmp.patch_from_text("@@ -1,21 +1,21 @@\n-%601234567890-=%5B%5D%5C;\',./\n+~!" + "@\#$%25%5E&*()_+%7B%7D%7C:%22%3C%3E?\n") }
      it { expect(diffs).to eq(patches.first.diffs) }
    end

    context "when there's a long string with repeats" do
      let(:text1) { "abcdef" * 100 }
      let(:text2) { text1 + "123" }
      let(:expected_patch) { "@@ -573,28 +573,31 @@\n cdefabcdefabcdefabcdefabcdef\n+123\n" }
      let(:patches) { dmp.patch_make(text1, text2) }

      it { expect(dmp.patch_to_text(patches)).to eq(expected_patch) }
    end
  end

  describe "#patch_split_max" do
    before { dmp.patch_split_max(patches) }

    context "when theres a long patch sequence" do
      let(:expected_patch) do
        "@@ -1,32 +1,46 @@\n+X\n ab\n+X\n cd\n+X\n ef\n+X\n gh\n+X\n " \
          "ij\n+X\n kl\n+X\n mn\n+X\n op\n+X\n qr\n+X\n st\n+X\n uv\n+X\n " \
          "wx\n+X\n yz\n+X\n 012345\n@@ -25,13 +39,18 @@\n zX01\n+X\n 23\n+X\n " \
          "45\n+X\n 67\n+X\n 89\n+X\n 0\n"
      end

      let(:patches) do
        dmp.patch_make(
          "abcdefghijklmnopqrstuvwxyz01234567890",
          "XabXcdXefXghXijXklXmnXopXqrXstXuvXwxXyzX01X23X45X67X89X0"
        )
      end

      it { expect(dmp.patch_to_text(patches)).to eq(expected_patch) }
    end

    context "when it cannot be split and reduced" do
      let!(:expected_patch) { dmp.patch_to_text(patches) }
      let(:patches) do
        dmp.patch_make(
          "abcdef1234567890123456789012345678901234567890" + "123456789012345678901234567890uvwxyz",
          "abcdefuvwxyz"
        )
      end

      it { expect(dmp.patch_to_text(patches)).to eq(expected_patch) }
    end

    context "when considering edge case #1" do
      let(:patches) { dmp.patch_make("1234567890123456789012345678901234567890123456789012345678901234567890", "abc") }
      let(:expected_patch) do
        "@@ -1,32 +1,4 @@\n-1234567890123456789012345678\n 9012\n"\
        "@@ -29,32 +1,4 @@\n-9012345678901234567890123456\n 7890\n"\
        "@@ -57,14 +1,3 @@\n-78901234567890\n+abc\n"
      end

      it { expect(dmp.patch_to_text(patches)).to eq(expected_patch) }
    end

    context "when considering edge case #2" do
      let(:patches) do
        dmp.patch_make(
          "abcdefghij , h : 0 , t : 1 abcdefghij , h : 0 , t : 1 abcdefghij , h : 0 , t : 1",
          "abcdefghij , h : 1 , t : 1 abcdefghij , h : 1 , t : 1 abcdefghij , h : 0 , t : 1"
        )
      end
      let(:expected_patch) do
        "@@ -2,32 +2,32 @@\n bcdefghij , h : \n-0\n+1\n  , t : 1 abcdef\n" \
          "@@ -29,32 +29,32 @@\n bcdefghij , h : \n-0\n+1\n  , t : 1 abcdef\n"
      end

      it { expect(dmp.patch_to_text(patches)).to eq(expected_patch) }
    end
  end

  describe "#patch_add_padding" do
    shared_examples "has before and after expectations" do
      it do
        expect { dmp.patch_add_padding(patches) }
          .to change { dmp.patch_to_text(patches) }
          .from(expect_patch)
          .to(expect_padding)
      end
    end

    context "when edges are full" do
      let(:patches)        { dmp.patch_make("", "test") }
      let(:expect_patch)   { "@@ -0,0 +1,4 @@\n+test\n" }
      let(:expect_padding) { "@@ -1,8 +1,12 @@\n %01%02%03%04\n+test\n %01%02%03%04\n" }
      it_behaves_like "has before and after expectations"
    end

    context "when edges are partial" do
      let(:patches)        { dmp.patch_make("XY", "XtestY") }
      let(:expect_patch)   { "@@ -1,2 +1,6 @@\n X\n+test\n Y\n" }
      let(:expect_padding) { "@@ -2,8 +2,12 @@\n %02%03%04X\n+test\n Y%01%02%03\n" }
      it_behaves_like "has before and after expectations"
    end

    context "when both edges are none" do
      let(:patches) { dmp.patch_make("XXXXYYYY", "XXXXtestYYYY") }
      let(:expect_patch)   { "@@ -1,8 +1,12 @@\n XXXX\n+test\n YYYY\n" }
      let(:expect_padding) { "@@ -5,8 +5,12 @@\n XXXX\n+test\n YYYY\n" }
      it_behaves_like "has before and after expectations"
    end
  end

  describe "#patch_apply" do
    let!(:text1) { "The quick brown fox jumps over the lazy dog." }
    let!(:text2) { "That quick brown fox jumped over a lazy dog." }
    before do
      dmp.match_distance         = 1000
      dmp.match_threshold        = 0.5
      dmp.patch_delete_threshold = 0.5
    end

    shared_examples "has before and after expectations" do
      let(:applied_patch) { dmp.patch_apply(patches, patch_text) }
      it { expect(applied_patch).to eq(expected_results) }
    end

    context "when null case occurs" do
      let(:patches)          { dmp.patch_make("", "") }
      let(:patch_text)       { "Hello World." }
      let(:expected_results) { ["Hello World.", []] }

      it_behaves_like "has before and after expectations"
    end

    context "when exact match" do
      let(:patches)          { dmp.patch_make(text1, text2) }
      let(:patch_text)       { text1 }
      let(:expected_results) { [text2, [true, true]] }

      it_behaves_like "has before and after expectations"
    end

    context "when exact edge match" do
      let(:patches) { dmp.patch_make("", "test") }
      let(:patch_text) { "" }
      let(:expected_results) { ["test", [true]] }

      it_behaves_like "has before and after expectations"
    end

    context "when partial match #1" do
      let(:patches)          { dmp.patch_make(text1, text2) }
      let(:patch_text)       { "The quick brown fox jumps over the lazy dog." }
      let(:expected_results) { ["That quick brown fox jumped over a lazy dog.", [true, true]] }

      it_behaves_like "has before and after expectations"
    end

    context "when partial match #2" do
      let(:patches)          { dmp.patch_make(text1, text2) }
      let(:patch_text)       { "The quick red rabbit jumps over the tired tiger." }
      let(:expected_results) { ["That quick red rabbit jumped over a tired tiger.", [true, true]] }

      # before { dmp.patch_apply(patches, 'The quick brown fox jumps over the lazy dog.') }

      it_behaves_like "has before and after expectations"
    end

    context "when partial match #3" do
      let(:patches)          { dmp.patch_make("y", "y123") }
      let(:patch_text)       { "x" }
      let(:expected_results) { ["x123", [true]] }

      it_behaves_like "has before and after expectations"
    end

    context "when near edge match" do
      let(:patches) { dmp.patch_make("XY", "XtestY") }
      let(:patch_text) { "XY" }
      let(:expected_results) { ["XtestY", [true]] }

      it_behaves_like "has before and after expectations"
    end

    context "when there's a failed match" do
      let(:patches)          { dmp.patch_make(text1, text2) }
      let(:patch_text)       { "I am the very model of a modern major general." }
      let(:expected_results) { [patch_text, [false, false]] }

      it_behaves_like "has before and after expectations"
    end

    context "when changes are in place" do
      let(:patches) { dmp.patch_make("x1234567890123456789012345678901234567890123456789012345678901234567890y", "xabcy") }

      context "when big delete and small change" do
        let(:patch_text) { "x123456789012345678901234567890-----++++++++++-----" + "123456789012345678901234567890y" }
        let(:expected_results) { ["xabcy", [true, true]] }

        it_behaves_like "has before and after expectations"
      end

      context "when there's a big change 1" do
        let(:patch_text) { "x12345678901234567890---------------++++++++++---------------" + "12345678901234567890y" }
        let(:expected_results) { ["xabc12345678901234567890---------------++++++++++---------------12345678901234567890y", [false, true]] }

        it_behaves_like "has before and after expectations"
      end

      context "Big delete big change 2" do
        let(:patch_text) { "x12345678901234567890---------------++++++++++---------------" + "12345678901234567890y" }
        let(:expected_results) { ["xabcy", [true, true]] }

        before { dmp.patch_delete_threshold = 0.6 }

        it_behaves_like "has before and after expectations"
      end
    end

    context "when a patch fails" do
      let(:patches) do
        dmp.patch_make(
          "abcdefghijklmnopqrstuvwxyz--------------------1234567890",
          "abcXXXXXXXXXXdefghijklmnopqrstuvwxyz--------------------1234567YYYYYYYYYY890"
        )
      end
      let(:patch_text)       { "ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567890" }
      let(:expected_results) { ["ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567YYYYYYYYYY890", [false, true]] }

      before do
        dmp.match_threshold        = 0.0
        dmp.match_distance         = 0
        dmp.patch_delete_threshold = 0.5
      end

      it_behaves_like "has before and after expectations"
    end
  end

  def new_delete_node(text)
    FastDiffMatchPatch::DiffNode.new(:delete, text)
  end

  def new_insert_node(text)
    FastDiffMatchPatch::DiffNode.new(:insert, text)
  end

  def new_equal_node(text)
    FastDiffMatchPatch::DiffNode.new(:equal, text)
  end
end
