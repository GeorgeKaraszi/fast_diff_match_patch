# frozen_string_literal: true

require "spec_helper"

RSpec.describe FastDiffMatchPatch do
  let(:dmp) { described_class.new }

  describe "#diff_common_prefix" do
    it do
      expect(dmp.diff_common_prefix("abc", "xyz")).to eq(0)
      expect(dmp.diff_common_prefix("1234abcdef", "1234xyz")).to eq(4)
      expect(dmp.diff_common_prefix("1234", "1234xyz")).to eq(4)
    end
  end

  describe "#diff_common_suffix" do
    it do
      expect(dmp.diff_common_suffix("abc", "xyz")).to eq(0)
      expect(dmp.diff_common_suffix("abcdef1234", "xyz1234")).to eq(4)
      expect(dmp.diff_common_suffix("1234", "xyz1234")).to eq(4)
    end
  end

  describe "#diff_common_overlap" do
    it do
      expect(dmp.diff_common_overlap("", "abcd")).to eq(0)
      expect(dmp.diff_common_overlap("abc", "abcd")).to eq(3)
      expect(dmp.diff_common_overlap("123456", "abcd")).to eq(0)
      expect(dmp.diff_common_overlap("123456xxx", "xxxabcd")).to eq(3)
      expect(dmp.diff_common_overlap("fi", '\ufb01i')).to eq(0)
    end
  end

  describe "#diff_half_match" do
    it "Optimal matches" do
      dmp.diff_timeout = 1
      expect(dmp.diff_half_match("1234567890", "abcdef")).to be_nil
      expect(dmp.diff_half_match("12345", "23")).to be_nil
      expect(dmp.diff_half_match("1234567890", "a345678z")).to eq(["12", "90", "a", "z", "345678"])
      expect(dmp.diff_half_match("abc56789z", "1234567890")).to eq(["abc", "z", "1234", "0", "56789"])
      expect(dmp.diff_half_match("a23456xyz", "1234567890")).to eq(["a", "xyz", "1", "7890", "23456"])
      expect(dmp.diff_half_match("121231234123451234123121", "a1234123451234z")).to eq(["12123", "123121", "a", "z", "1234123451234"])
      expect(dmp.diff_half_match("x-=-=-=-=-=-=-=-=-=-=-=-=", "xx-=-=-=-=-=-=-=")).to eq(["", "-=-=-=-=-=", "x", "", "x-=-=-=-=-=-=-="])
      expect(dmp.diff_half_match("-=-=-=-=-=-=-=-=-=-=-=-=y", "-=-=-=-=-=-=-=yy")).to eq(["-=-=-=-=-=", "", "", "y", "-=-=-=-=-=-=-=y"])
      expect(dmp.diff_half_match("qHilloHelloHew", "xHelloHeHulloy")).to eq(["qHillo", "w", "x", "Hulloy", "HelloHe"])
    end

    it "optimal matches" do
      dmp.diff_timeout = 0
      expect(dmp.diff_half_match("qHilloHelloHew", "xHelloHeHulloy")).to be_nil
    end
  end

  describe "#diff_lines_to_chars" do
    it "converts ascii to UTF-8 encodings" do
      expect(dmp.diff_lines_to_chars("alpha\nbeta\nalpha\n", "beta\nalpha\nbeta\n")).to eq(["\x01\x02\x01", "\x02\x01\x02", ["", "alpha\n", "beta\n"]])
      expect(dmp.diff_lines_to_chars("", "alpha\r\nbeta\r\n\r\n\r\n")).to eq(["", "\x01\x02\x03\x03", ["", "alpha\r\n", "beta\r\n", "\r\n"]])
      expect(dmp.diff_lines_to_chars("a", "b")).to eq(["\x01", "\x02", ["", "a", "b"]])
    end

    it "Revels 8-bit limitations" do
      n = 300
      line_list = (1..n).map { |x| x.to_s + "\n" }
      char_list = (1..n).map { |x| x.chr(Encoding::UTF_8) }
      lines = line_list.join
      chars = char_list.join
      expect(n).to eq(line_list.length)
      expect(n).to eq(chars.length)

      line_list.unshift("")
      expect(dmp.diff_lines_to_chars(lines, "")).to eq([chars, "", line_list])
    end
  end

  describe "#diff_chars_to_lines" do
    let(:diffs) { [equal_node("\x01\x02\x01"), insert_node("\x02\x01\x02")] }

    it "converts unicode back to ascii" do
      expect { dmp.diff_chars_to_lines(diffs, ["", "alpha\n", "beta\n"]) }
        .to change { diffs }.to([equal_node("alpha\nbeta\nalpha\n"), insert_node("beta\nalpha\nbeta\n")])
    end

    it "Handel's large sets" do
      n = 300
      line_list = (1..n).map { |x| x.to_s + "\n" }
      char_list = (1..n).map { |x| x.chr(Encoding::UTF_8) }
      lines = line_list.join
      chars = char_list.join

      expect(n).to eq(line_list.length)
      expect(n).to eq(chars.length)
      line_list.unshift("")

      diffs = [delete_node(chars)]
      expect { dmp.diff_chars_to_lines(diffs, line_list) }.to change { diffs }.to([delete_node(lines)])
    end
  end

  describe "#diff_cleanup_merge" do
    it "has no changed case" do
      diffs = [equal_node("a"), delete_node("b"), insert_node("c")]
      expect { dmp.diff_cleanup_merge(diffs) }.to_not change { diffs }
    end

    it "Merges Equalities" do
      diffs = [equal_node("a"), equal_node("b"), equal_node("c")]
      expect_cleanup_change(diffs, [equal_node("abc")])
    end

    it "Merges deletions" do
      diffs = [delete_node("a"), delete_node("b"), delete_node("c")]
      expect_cleanup_change(diffs, [delete_node("abc")])
    end

    it "Merges insertions" do
      diffs = [insert_node("a"), insert_node("b"), insert_node("c")]
      expect_cleanup_change(diffs, [insert_node("abc")])
    end

    it "Merges interweaved" do
      diffs = [
        delete_node("a"), insert_node("b"), delete_node("c"),
        insert_node("d"), equal_node("e"), equal_node("f")
      ]

      expect_cleanup_change(diffs, [delete_node("ac"), insert_node("bd"), equal_node("ef")])
    end

    it "slide edit left" do
      diffs = [equal_node("a"), insert_node("ba"), equal_node("c")]
      expect_cleanup_change(diffs, [insert_node("ab"), equal_node("ac")])
    end

    it "slide edit right" do
      diffs = [equal_node("c"), insert_node("ab"), equal_node("a")]
      expect_cleanup_change(diffs, [equal_node("ca"), insert_node("ba")])
    end

    it "slide edit recursive" do
      diffs = [
        equal_node("a"), delete_node("b"), equal_node("c"),
        delete_node("ac"), equal_node("x")
      ]

      expect_cleanup_change(diffs, [delete_node("abc"), equal_node("acx")])
    end

    it "slide edit right recursive" do
      diffs = [
        equal_node("x"), delete_node("ca"), equal_node("c"),
        delete_node("b"), equal_node("a")
      ]

      expect_cleanup_change(diffs, [equal_node("xca"), delete_node("cba")])
    end

    context "when a Pre/suffix is detected" do
      it "unpacks insert and delete" do
        diffs = [delete_node("a"), insert_node("abc"), delete_node("dc")]
        expect_cleanup_change(diffs, [equal_node("a"), delete_node("d"), insert_node("b"), equal_node("c")])
      end

      it "unpacks equalities" do
        diffs = [
          equal_node("x"), delete_node("a"), insert_node("abc"),
          delete_node("dc"), equal_node("y")
        ]

        expect_cleanup_change(diffs, [equal_node("xa"), delete_node("d"), insert_node("b"), equal_node("cy")])
      end
    end

    def expect_cleanup_change(diffs, results)
      expect { dmp.diff_cleanup_merge(diffs) }.to change { diffs }.to(results)
    end
  end

  describe "#diff_cleanup_semantic_lossless" do
    it "handel nil cases" do
      diffs = []
      expect { dmp.diff_cleanup_semantic_lossless(diffs) }.to_not change { diffs }
    end

    it "handel's blank lines" do
      diffs = [
        equal_node("AAA\r\n\r\nBBB"),
        insert_node("\r\nDDD\r\n\r\nBBB"),
        equal_node("\r\nEEE")
      ]

      expect_semantic_change(
        diffs,
        [
          equal_node("AAA\r\n\r\n"),
          insert_node("BBB\r\nDDD\r\n\r\n"),
          equal_node("BBB\r\nEEE")
        ]
      )
    end

    it "handel's line boundaries" do
      diffs = [equal_node("AAA\r\nBBB"), insert_node(" DDD\r\nBBB"), equal_node(" EEE")]
      expect_semantic_change(diffs, [equal_node("AAA\r\n"), insert_node("BBB DDD\r\n"), equal_node("BBB EEE")])
    end

    it "handel's word boundaries" do
      diffs = [equal_node("The c"), insert_node("ow and the c"), equal_node("at.")]
      expect_semantic_change(diffs, [equal_node("The "), insert_node("cow and the "), equal_node("cat.")])
    end

    it "handel's alphanumeric boundaries" do
      diffs = [equal_node("The-c"), insert_node("ow-and-the-c"), equal_node("at.")]
      expect_semantic_change(diffs, [equal_node("The-"), insert_node("cow-and-the-"), equal_node("cat.")])
    end

    it "hits the start" do
      diffs = [equal_node("a"), delete_node("a"), equal_node("ax")]
      expect_semantic_change(diffs, [delete_node("a"), equal_node("aax")])
    end

    it "hits the end" do
      diffs = [equal_node("xa"), delete_node("a"), equal_node("a")]
      expect_semantic_change(diffs, [equal_node("xaa"), delete_node("a")])
    end

    def expect_semantic_change(diffs, results)
      expect { dmp.diff_cleanup_semantic_lossless(diffs) }.to change { diffs }.to(results)
    end
  end

  describe "#diff_cleanup_semantic" do
    context "when it does nothing" do
      it "handel's nil case" do
        diffs = []
        expect { dmp.diff_cleanup_semantic(diffs) }.to_not change { diffs }
      end

      it "doesn't eliminate #1" do
        diffs = [delete_node("ab"), insert_node("cd"), equal_node("12"), delete_node("e")]
        expect { dmp.diff_cleanup_semantic(diffs) }.to_not change { diffs }
      end

      it "doesn't eliminate #2" do
        diffs = [
          delete_node("abc"), insert_node("ABC"),
          equal_node("1234"), delete_node("wxyz")
        ]
        expect { dmp.diff_cleanup_semantic(diffs) }.to_not change { diffs }
      end

      it "does not do overlap elimination" do
        diffs = [delete_node("abcxx"), insert_node("xxdef")]
        expect { dmp.diff_cleanup_semantic(diffs) }.to_not change { diffs }
      end
    end

    context "When a change is made" do
      it "simple elmination" do
        diffs = [delete_node("a"), equal_node("b"), delete_node("c")]
        expect_semantic_change(diffs, [delete_node("abc"), insert_node("b")])
      end

      it "backpass elmination" do
        diffs = [
          delete_node("ab"), equal_node("cd"), delete_node("e"),
          equal_node("f"), insert_node("g")
        ]

        expect_semantic_change(diffs, [delete_node("abcdef"), insert_node("cdfg")])
      end

      it "does multiple elminations" do
        diffs = [
          insert_node("1"), equal_node("A"), delete_node("B"),
          insert_node("2"), equal_node("_"), insert_node("1"),
          equal_node("A"), delete_node("B"), insert_node("2")
        ]

        expect_semantic_change(diffs, [delete_node("AB_AB"), insert_node("1A2_1A2")])
      end

      it "handel's word boundaires" do
        diffs = [equal_node("The c"), delete_node("ow and the c"), equal_node("at.")]
        expect_semantic_change(diffs, [equal_node("The "), delete_node("cow and the "), equal_node("cat.")])
      end

      it "does overlap elmination" do
        diffs = [delete_node("abcxxx"), insert_node("xxxdef")]
        expect_semantic_change(diffs, [delete_node("abc"), equal_node("xxx"), insert_node("def")])
      end

      it "does two overlap elminations" do
        diffs = [
          delete_node("abcd1212"), insert_node("1212efghi"), equal_node("----"),
          delete_node("A3"), insert_node("3BC")
        ]

        expect_semantic_change(
          diffs,
          [
            delete_node("abcd"), equal_node("1212"), insert_node("efghi"),
            equal_node("----"), delete_node("A"), equal_node("3"), insert_node("BC")
          ]
        )
      end

      def expect_semantic_change(diffs, results)
        expect { dmp.diff_cleanup_semantic(diffs) }.to change { diffs }.to(results)
      end
    end
  end

  describe "#diff_bisect" do
    it "breaks apart word differences" do
      a     = "cat"
      b     = "map"
      diffs = [delete_node("c"), insert_node("m"), equal_node("a"), delete_node("t"), insert_node("p")]
      expect(dmp.diff_bisect(a, b, nil)).to eq(diffs)
    end

    it "can time out" do
      a     = "cat"
      b     = "map"
      expect(dmp.diff_bisect(a, b, Time.now - 1)).to eq([delete_node("cat"), insert_node("map")])
    end
  end

  describe "#diff_main" do
    it "can handel empty strings" do
      expect(dmp.diff_main("", "", false)).to eq([])
    end

    it "can handel total equality strings" do
      expect(dmp.diff_main("abc", "abc", false)).to eq([equal_node("abc")])
    end

    it "can handel simple insertion" do
      expect(dmp.diff_main("abc", "ab123c", false)).to eq([equal_node("ab"), insert_node("123"), equal_node("c")])
    end

    it "can handel simple deletion" do
      expect(dmp.diff_main("a123bc", "abc", false)).to eq([equal_node("a"), delete_node("123"), equal_node("bc")])
    end

    it "can handel multiple insertions" do
      diff = [
        equal_node("a"), insert_node("123"), equal_node("b"),
        insert_node("456"), equal_node("c")
      ]
      expect(dmp.diff_main("abc", "a123b456c", false)).to eq(diff)
    end

    it "can handel multiple deletions" do
      diff = [
        equal_node("a"), delete_node("123"), equal_node("b"),
        delete_node("456"), equal_node("c")
      ]
      expect(dmp.diff_main("a123b456c", "abc", false)).to eq(diff)
    end

    context "when timeout is switched off" do
      before { dmp.diff_timeout = 0 }

      it "can handel simple case" do
        expect(dmp.diff_main("a", "b", false)).to eq([delete_node("a"), insert_node("b")])
      end

      it "can handel a mixture of insertions and deletions in ascii" do
        diffs = [
          delete_node("Apple"), insert_node("Banana"), equal_node("s are a"),
          insert_node("lso"), equal_node(" fruit.")
        ]

        expect(dmp.diff_main("Apples are a fruit.", "Bananas are also fruit.", false)).to eq(diffs)
      end

      it "can handel a mixture of insertions and deletions in unicode" do
        diffs = [
          delete_node("a"), insert_node("\u0680"), equal_node("x"),
          delete_node("\t"), insert_node("\0")
        ]

        expect(dmp.diff_main("ax\t", "\u0680x\0", false)).to eq(diffs)
      end

      it "can handel overlaps" do
        diffs = [
          delete_node("1"), equal_node("a"), delete_node("y"),
          equal_node("b"), delete_node("2"), insert_node("xab")
        ]

        expect(dmp.diff_main("1ayb2", "abxab", false)).to eq(diffs)
      end

      it "can handel prefix's" do
        expect(dmp.diff_main("abcy", "xaxcxabc", false)).to eq([insert_node("xaxcx"), equal_node("abc"), delete_node("y")])
      end

      it "can handel suffix's" do
        diffs = [
          delete_node("ABCD"),
          equal_node("a"),
          delete_node("="),
          insert_node("-"),
          equal_node("bcd"),
          delete_node("="),
          insert_node("-"),
          equal_node("efghijklmnopqrs"),
          delete_node("EFGHIJKLMNOefg")
        ]
        expect(dmp.diff_main("ABCDa=bcd=efghijklmnopqrsEFGHIJKLMNOefg", "a-bcd-efghijklmnopqrs", false)).to eq(diffs)
      end

      it "can handel large equalities" do
        diffs = [
          insert_node(" "), equal_node("a"), insert_node("nd"),
          equal_node(" [[Pennsylvania]]"), delete_node(" and [[New")
        ]

        expect(dmp.diff_main("a [[Pennsylvania]] and [[New", " and [[Pennsylvania]]", false)).to eq(diffs)
      end
    end

    context "when using line mode" do
      it "can handel simple multi-line mode" do
        a = "1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n"\
              "1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n"\
              "1234567890\n1234567890\n1234567890\n"
        b = "abcdefghij\nabcdefghij\nabcdefghij\nabcdefghij\nabcdefghij\n"\
              "abcdefghij\nabcdefghij\nabcdefghij\nabcdefghij\nabcdefghij\n"\
              "abcdefghij\nabcdefghij\nabcdefghij\n"

        expect(dmp.diff_main(a, b, false)).to eq(dmp.diff_main(a, b, true))
      end

      it "can handel single line mode" do
        a = "123456789012345678901234567890123456789012345678901234567890"\
              "123456789012345678901234567890123456789012345678901234567890"\
              "1234567890"
        b = "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij"\
              "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij"

        expect(dmp.diff_main(a, b, false)).to eq(dmp.diff_main(a, b, true))
      end

      it "can handel overlap line mode" do
        a = "1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n"\
              "1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n"\
              "1234567890\n1234567890\n1234567890\n"
        b = "abcdefghij\n1234567890\n1234567890\n1234567890\nabcdefghij\n"\
              "1234567890\n1234567890\n1234567890\nabcdefghij\n1234567890\n"\
              "1234567890\n1234567890\nabcdefghij\n"

        expect(dmp.diff_text1(dmp.diff_main(a, b, false))).to eq(dmp.diff_text1(dmp.diff_main(a, b, true)))
      end
    end
  end

  def delete_node(text)
    FastDiffMatchPatch::DiffNode.new(:DELETE, text)
  end

  def insert_node(text)
    FastDiffMatchPatch::DiffNode.new(:INSERT, text)
  end

  def equal_node(text)
    FastDiffMatchPatch::DiffNode.new(:EQUAL, text)
  end
end
