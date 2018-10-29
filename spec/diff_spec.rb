# frozen_string_literal: true

require "spec_helper"

module GoogleDiffMatchPatch
  RSpec.describe Diff do
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
      let(:diffs) { [[:equal, "\x01\x02\x01"], [:insert, "\x02\x01\x02"]] }

      it "converts unicode back to ascii" do
        expect { dmp.diff_chars_to_lines(diffs, ["", "alpha\n", "beta\n"]) }
          .to change { diffs }.to([[:equal, "alpha\nbeta\nalpha\n"], [:insert, "beta\nalpha\nbeta\n"]])
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

        diffs = [[:delete, chars]]
        expect { dmp.diff_chars_to_lines(diffs, line_list) }.to change { diffs }.to([[:delete, lines]])
      end
    end

    describe "#diff_cleanup_merge" do
      it "has no changed case" do
        diffs = [[:equal, "a"], [:delete, "b"], [:insert, "c"]]
        expect { dmp.diff_cleanup_merge(diffs) }.to_not change { diffs }
      end

      it "Merges Equalities" do
        diffs = [[:equal, "a"], [:equal, "b"], [:equal, "c"]]
        expect_cleanup_change(diffs, [[:equal, "abc"]])
      end

      it "Merges deletions" do
        diffs = [[:delete, "a"], [:delete, "b"], [:delete, "c"]]
        expect_cleanup_change(diffs, [[:delete, "abc"]])
      end

      it "Merges insertions" do
        diffs = [[:insert, "a"], [:insert, "b"], [:insert, "c"]]
        expect_cleanup_change(diffs, [[:insert, "abc"]])
      end

      it "Merges interweaved" do
        diffs = [
          [:delete, "a"], [:insert, "b"], [:delete, "c"],
          [:insert, "d"], [:equal, "e"], [:equal, "f"]
        ]

        expect_cleanup_change(diffs, [[:delete, "ac"], [:insert, "bd"], [:equal, "ef"]])
      end

      it "slide edit left" do
        diffs = [[:equal, "a"], [:insert, "ba"], [:equal, "c"]]
        expect_cleanup_change(diffs, [[:insert, "ab"], [:equal, "ac"]])
      end

      it "slide edit right" do
        diffs = [[:equal, "c"], [:insert, "ab"], [:equal, "a"]]
        expect_cleanup_change(diffs, [[:equal, "ca"], [:insert, "ba"]])
      end

      it "slide edit recursive" do
        diffs = [
          [:equal, "a"], [:delete, "b"], [:equal, "c"],
          [:delete, "ac"], [:equal, "x"]
        ]

        expect_cleanup_change(diffs, [[:delete, "abc"], [:equal, "acx"]])
      end

      it "slide edit right recursive" do
        diffs = [
          [:equal, "x"], [:delete, "ca"], [:equal, "c"],
          [:delete, "b"], [:equal, "a"]
        ]

        expect_cleanup_change(diffs, [[:equal, "xca"], [:delete, "cba"]])
      end

      context "when a Pre/suffix is detected" do
        it "unpacks insert and delete" do
          diffs = [[:delete, "a"], [:insert, "abc"], [:delete, "dc"]]
          expect_cleanup_change(diffs, [[:equal, "a"], [:delete, "d"], [:insert, "b"], [:equal, "c"]])
        end

        it "unpacks equalities" do
          diffs = [
            [:equal, "x"], [:delete, "a"], [:insert, "abc"],
            [:delete, "dc"], [:equal, "y"]
          ]

          expect_cleanup_change(diffs, [[:equal, "xa"], [:delete, "d"], [:insert, "b"], [:equal, "cy"]])
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
          [:equal, "AAA\r\n\r\nBBB"],
          [:insert, "\r\nDDD\r\n\r\nBBB"],
          [:equal, "\r\nEEE"]
        ]

        expect_semantic_change(
          diffs,
          [
            [:equal, "AAA\r\n\r\n"],
            [:insert, "BBB\r\nDDD\r\n\r\n"],
            [:equal, "BBB\r\nEEE"]
          ]
        )
      end

      it "handel's line boundaries" do
        diffs = [[:equal, "AAA\r\nBBB"], [:insert, " DDD\r\nBBB"], [:equal, " EEE"]]
        expect_semantic_change(diffs, [[:equal, "AAA\r\n"], [:insert, "BBB DDD\r\n"], [:equal, "BBB EEE"]])
      end

      it "handel's word boundaries" do
        diffs = [[:equal, "The c"], [:insert, "ow and the c"], [:equal, "at."]]
        expect_semantic_change(diffs, [[:equal, "The "], [:insert, "cow and the "], [:equal, "cat."]])
      end

      it "handel's alphanumeric boundaries" do
        diffs = [[:equal, "The-c"], [:insert, "ow-and-the-c"], [:equal, "at."]]
        expect_semantic_change(diffs, [[:equal, "The-"], [:insert, "cow-and-the-"], [:equal, "cat."]])
      end

      it "hits the start" do
        diffs = [[:equal, "a"], [:delete, "a"], [:equal, "ax"]]
        expect_semantic_change(diffs, [[:delete, "a"], [:equal, "aax"]])
      end

      it "hits the end" do
        diffs = [[:equal, "xa"], [:delete, "a"], [:equal, "a"]]
        expect_semantic_change(diffs, [[:equal, "xaa"], [:delete, "a"]])
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
          diffs = [[:delete, "ab"], [:insert, "cd"], [:equal, "12"], [:delete, "e"]]
          expect { dmp.diff_cleanup_semantic(diffs) }.to_not change { diffs }
        end

        it "doesn't eliminate #2" do
          diffs = [
            [:delete, "abc"], [:insert, "ABC"],
            [:equal, "1234"], [:delete, "wxyz"]
          ]
          expect { dmp.diff_cleanup_semantic(diffs) }.to_not change { diffs }
        end

        it "does not do overlap elimination" do
          diffs = [[:delete, "abcxx"], [:insert, "xxdef"]]
          expect { dmp.diff_cleanup_semantic(diffs) }.to_not change { diffs }
        end
      end

      context "When a change is made" do
        it "simple elmination" do
          diffs = [[:delete, "a"], [:equal, "b"], [:delete, "c"]]
          expect_semantic_change(diffs, [[:delete, "abc"], [:insert, "b"]])
        end

        it "backpass elmination" do
          diffs = [
            [:delete, "ab"], [:equal, "cd"], [:delete, "e"],
            [:equal, "f"], [:insert, "g"]
          ]

          expect_semantic_change(diffs, [[:delete, "abcdef"], [:insert, "cdfg"]])
        end

        it "does multiple elminations" do
          diffs = [
            [:insert, "1"], [:equal, "A"], [:delete, "B"],
            [:insert, "2"], [:equal, "_"], [:insert, "1"],
            [:equal, "A"], [:delete, "B"], [:insert, "2"]
          ]

          expect_semantic_change(diffs, [[:delete, "AB_AB"], [:insert, "1A2_1A2"]])
        end

        it "handel's word boundaires" do
          diffs = [[:equal, "The c"], [:delete, "ow and the c"], [:equal, "at."]]
          expect_semantic_change(diffs, [[:equal, "The "], [:delete, "cow and the "], [:equal, "cat."]])
        end

        it "does overlap elmination" do
          diffs = [[:delete, "abcxxx"], [:insert, "xxxdef"]]
          expect_semantic_change(diffs, [[:delete, "abc"], [:equal, "xxx"], [:insert, "def"]])
        end

        it "does two overlap elminations" do
          diffs = [
            [:delete, "abcd1212"], [:insert, "1212efghi"], [:equal, "----"],
            [:delete, "A3"], [:insert, "3BC"]
          ]

          expect_semantic_change(
            diffs,
            [
              [:delete, "abcd"], [:equal, "1212"], [:insert, "efghi"],
              [:equal, "----"], [:delete, "A"], [:equal, "3"], [:insert, "BC"]
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
        diffs = [[:delete, "c"], [:insert, "m"], [:equal, "a"], [:delete, "t"], [:insert, "p"]]
        expect(dmp.diff_bisect(a, b, nil)).to eq(diffs)
      end

      it "can time out" do
        a     = "cat"
        b     = "map"
        expect(dmp.diff_bisect(a, b, Time.now - 1)).to eq([[:delete, "cat"], [:insert, "map"]])
      end
    end

    describe "#diff_main" do
      it "can handel empty strings" do
        expect(dmp.diff_main("", "", false)).to eq([])
      end

      it "can handel total equality strings" do
        expect(dmp.diff_main("abc", "abc", false)).to eq([[:equal, "abc"]])
      end

      it "can handel simple insertion" do
        expect(dmp.diff_main("abc", "ab123c", false)).to eq([[:equal, "ab"], [:insert, "123"], [:equal, "c"]])
      end

      it "can handel simple deletion" do
        expect(dmp.diff_main("a123bc", "abc", false)).to eq([[:equal, "a"], [:delete, "123"], [:equal, "bc"]])
      end

      it "can handel multiple insertions" do
        diff = [
          [:equal, "a"], [:insert, "123"], [:equal, "b"],
          [:insert, "456"], [:equal, "c"]
        ]
        expect(dmp.diff_main("abc", "a123b456c", false)).to eq(diff)
      end

      it "can handel multiple deletions" do
        diff = [
          [:equal, "a"], [:delete, "123"], [:equal, "b"],
          [:delete, "456"], [:equal, "c"]
        ]
        expect(dmp.diff_main("a123b456c", "abc", false)).to eq(diff)
      end

      context "when timeout is switched off" do
        before { dmp.diff_timeout = 0 }

        it "can handel simple case" do
          expect(dmp.diff_main("a", "b", false)).to eq([[:delete, "a"], [:insert, "b"]])
        end

        it "can handel a mixture of insertions and deletions in ascii" do
          diffs = [
            [:delete, "Apple"], [:insert, "Banana"], [:equal, "s are a"],
            [:insert, "lso"], [:equal, " fruit."]
          ]

          expect(dmp.diff_main("Apples are a fruit.", "Bananas are also fruit.", false)).to eq(diffs)
        end

        it "can handel a mixture of insertions and deletions in unicode" do
          diffs = [
            [:delete, "a"], [:insert, "\u0680"], [:equal, "x"],
            [:delete, "\t"], [:insert, "\0"]
          ]

          expect(dmp.diff_main("ax\t", "\u0680x\0", false)).to eq(diffs)
        end

        it "can handel overlaps" do
          diffs = [
            [:delete, "1"], [:equal, "a"], [:delete, "y"],
            [:equal, "b"], [:delete, "2"], [:insert, "xab"]
          ]

          expect(dmp.diff_main("1ayb2", "abxab", false)).to eq(diffs)
        end

        it "can handel prefix's" do
          expect(dmp.diff_main("abcy", "xaxcxabc", false)).to eq([[:insert, "xaxcx"], [:equal, "abc"], [:delete, "y"]])
        end

        it "can handel suffix's" do
          diffs = [
            [:delete, "ABCD"], [:equal, "a"], [:delete, "="], [:insert, "-"],
            [:equal, "bcd"], [:delete, "="], [:insert, "-"],
            [:equal, "efghijklmnopqrs"], [:delete, "EFGHIJKLMNOefg"]
          ]
          expect(dmp.diff_main("ABCDa=bcd=efghijklmnopqrsEFGHIJKLMNOefg", "a-bcd-efghijklmnopqrs", false)).to eq(diffs)
        end

        it "can handel large equalities" do
          diffs = [
            [:insert, " "], [:equal, "a"], [:insert, "nd"],
            [:equal, " [[Pennsylvania]]"], [:delete, " and [[New"]
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
  end
end
