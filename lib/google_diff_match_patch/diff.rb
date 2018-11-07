# frozen_string_literal: true

# rubocop:disable Metrics/BlockNesting
module GoogleDiffMatchPatch
  class Diff
    attr_accessor :diff_timeout, :diff_edit_cost

    # Init's a diff_match_patch object with default settings.
    # Redefine these in your program to override the defaults.
    def initialize(**options)
      @diff_timeout   = options.delete(:diff_timeout)   || 1 # Number of seconds to map a diff before giving up (0 for infinity).
      @diff_edit_cost = options.delete(:diff_edit_cost) || 4 # Cost of an empty edit operation in terms of edit characters.
    end

    # Find the differences between two texts.  Simplifies the problem by
    # stripping any common prefix or suffix off the texts before diffing.
    def diff_main(text1, text2, check_lines = true, deadline = nil)
      raise ArgumentError.new("Null inputs. (diff_main)") if text1.nil? || text2.nil?

      # Check for equality (speedup).
      if text1 == text2
        return text1.empty? ? [] : [new_equal_node(text1)]
      end

      # Set a deadline by which time the diff must be complete.
      deadline      = Time.now + @diff_timeout if deadline.nil? && @diff_timeout.positive?
      check_lines   = true if check_lines.nil?
      common_prefix = nil
      common_suffix = nil

      # Trim off common prefix (speedup).
      common_length = diff_common_prefix(text1, text2)
      if common_length.nonzero?
        common_prefix = text1[0...common_length]
        text1         = text1[common_length..-1]
        text2         = text2[common_length..-1]
      end

      # Trim off common suffix (speedup).
      common_length = diff_common_suffix(text1, text2)
      if common_length.nonzero?
        common_suffix = text1[-common_length..-1]
        text1         = text1[0...-common_length]
        text2         = text2[0...-common_length]
      end

      # Compute the diff on the middle block.
      diffs = diff_compute(text1, text2, check_lines, deadline)

      # Restore the prefix and suffix.
      diffs.unshift(new_equal_node(common_prefix)) unless common_prefix.nil?
      diffs << new_equal_node(common_suffix)       unless common_suffix.nil?
      diffs.tap(&method(:diff_cleanup_merge))
    end

    # Find the differences between two texts.  Assumes that the texts do not
    # have any common prefix or suffix.
    def diff_compute(text1, text2, check_lines, deadline)
      # Just add some text (speedup).
      return [new_insert_node(text2)] if text1.empty?

      # Just delete some text (speedup).
      return [new_delete_node(text1)] if text2.empty?

      short_text, long_text = [text1, text2].sort_by(&:length)
      sub_index = long_text.index(short_text)

      unless sub_index.nil?
        operation = text1.length > text2.length ? :DELETE : :INSERT
        # Shorter text is inside the longer text (speedup).
        diffs = []
        diffs << Diff::Node.new(operation, long_text[0...sub_index])
        diffs << new_equal_node(short_text)
        diffs << Diff::Node.new(operation, long_text[(sub_index + short_text.length)..-1])

        return diffs
      end

      if short_text.length == 1
        # Single character string.
        # After the previous speedup, the character can't be an equality.
        return [new_delete_node(text1), new_insert_node(text2)]
      end

      # Check to see if the problem can be split in two.
      hm = diff_half_match(text1, text2)
      unless hm.nil?
        # A half-match was found, sort out the return data.
        text1_a, text1_b, text2_a, text2_b, mid_common = hm
        # Send both pairs off for separate processing.
        diffs_a = diff_main(text1_a, text2_a, check_lines, deadline)
        diffs_b = diff_main(text1_b, text2_b, check_lines, deadline)
        # Merge the results.
        return diffs_a + [new_equal_node(mid_common)] + diffs_b
      end

      if check_lines && text1.length > 100 && text2.length > 100
        return diff_line_mode(text1, text2, deadline)
      end

      diff_bisect(text1, text2, deadline)
    end

    # Do a quick line-level diff on both strings, then rediff the parts for
    # greater accuracy.
    # This speedup can produce non-minimal diffs.
    def diff_line_mode(text1, text2, deadline)
      # Scan the text on a line-by-line basis first.
      text1, text2, line_array = diff_lines_to_chars(text1, text2)
      diffs = diff_main(text1, text2, false, deadline)

      diff_chars_to_lines(diffs, line_array) # Convert the diff back to original text.
      diff_cleanup_semantic(diffs)           # Eliminate freak matches (e.g. blank lines)

      # Rediff any replacement blocks, this time character-by-character.
      # Add a dummy entry at the end.
      diffs << new_equal_node("")
      pointer      = 0
      count_delete = 0
      count_insert = 0
      text_delete  = ""
      text_insert  = ""

      while pointer < diffs.length
        case diffs[pointer].operation
        when :INSERT
          count_insert += 1
          text_insert  += diffs[pointer].text
        when :DELETE
          count_delete += 1
          text_delete  += diffs[pointer].text
        else # equal
          # Upon reaching an equality, check for prior redundancies.
          if count_delete.positive? && count_insert.positive?
            # Delete the offending records and add the merged ones.
            pointer = pointer - count_delete - count_insert
            diffs.slice!(pointer, count_delete + count_insert)
            sub_diffs         = diff_main(text_delete, text_insert, false, deadline)
            diffs[pointer, 0] = sub_diffs
            pointer          += sub_diffs.length
          end
          count_insert = 0
          count_delete = 0
          text_delete  = ""
          text_insert  = ""
        end
        pointer += 1
      end

      diffs.tap(&:pop) # Remove the dummy entry at the end.
    end

    # Find the 'middle snake' of a diff, split the problem in two
    # and return the recursively constructed diff.
    # See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.

    # rubocop:disable Style/ConditionalAssignment
    def diff_bisect(text1, text2, deadline)
      # Cache the text lengths to prevent multiple calls.
      text1_length     = text1.length
      text2_length     = text2.length
      delta            = text1_length - text2_length
      max_d            = (text1_length + text2_length + 1) / 2
      v_offset         = max_d
      v_length         = 2 * max_d
      v1               = Array.new(v_length, -1)
      v2               = Array.new(v_length, -1)
      v1[v_offset + 1] = 0
      v2[v_offset + 1] = 0

      # If the total number of characters is odd, then the front path will
      # collide with the reverse path.
      front = delta.odd?
      # Offsets for start and end of k loop.
      # Prevents mapping of space beyond the grid.
      k1start = 0
      k1end   = 0
      k2start = 0
      k2end   = 0
      0.upto(max_d - 1) do |d|
        # Bail out if deadline is reached.
        break if deadline && Time.now >= deadline

        # Walk the front path one step.
        (-d + k1start).step(d - k1end, 2) do |k1|
          k1_offset = v_offset + k1
          if k1 == -d || k1 != d && v1[k1_offset - 1] < v1[k1_offset + 1]
            x1 = v1[k1_offset + 1]
          else
            x1 = v1[k1_offset - 1] + 1
          end

          y1 = x1 - k1
          while x1 < text1_length && y1 < text2_length && text1[x1] == text2[y1]
            x1 += 1
            y1 += 1
          end

          v1[k1_offset] = x1
          if x1 > text1_length
            # Ran off the right of the graph.
            k1end += 2
          elsif y1 > text2_length
            # Ran off the bottom of the graph.
            k1start += 2
          elsif front
            k2_offset = v_offset + delta - k1
            if k2_offset >= 0 && k2_offset < v_length && v2[k2_offset] != -1
              # Mirror x2 onto top-left coordinate system.
              x2 = text1_length - v2[k2_offset]
              if x1 >= x2
                # Overlap detected.
                return diff_bisect_split(text1, text2, x1, y1, deadline)
              end
            end
          end
        end

        # Walk the reverse path one step.
        (-d + k2start).step(d - k2end, 2) do |k2|
          k2_offset = v_offset + k2
          if k2 == -d || k2 != d && v2[k2_offset - 1] < v2[k2_offset + 1]
            x2 = v2[k2_offset + 1]
          else
            x2 = v2[k2_offset - 1] + 1
          end

          y2 = x2 - k2
          while x2 < text1_length && y2 < text2_length && text1[-x2 - 1] == text2[-y2 - 1]
            x2 += 1
            y2 += 1
          end

          v2[k2_offset] = x2
          if x2 > text1_length
            # Ran off the left of the graph.
            k2end += 2
          elsif y2 > text2_length
            # Ran off the top of the graph.
            k2start += 2
          elsif !front
            k1_offset = v_offset + delta - k2
            if k1_offset >= 0 && k1_offset < v_length && v1[k1_offset] != -1
              x1 = v1[k1_offset]
              y1 = v_offset + x1 - k1_offset
              x2 = text1_length - x2 # Mirror x2 onto top-left coordinate system.
              if x1 >= x2
                # Overlap detected.
                return diff_bisect_split(text1, text2, x1, y1, deadline)
              end
            end
          end
        end
      end

      # Diff took too long and hit the deadline or
      # number of diffs equals number of characters, no commonality at all.
      [new_delete_node(text1), new_insert_node(text2)]
    end
    # rubocop:enable Style/ConditionalAssignment

    # Given the location of the 'middle snake', split the diff in two parts
    # and recurse.
    def diff_bisect_split(text1, text2, x, y, deadline)
      text1a = text1[0...x]
      text2a = text2[0...y]
      text1b = text1[x..-1]
      text2b = text2[y..-1]

      # Compute both diffs serially.
      diffs_a = diff_main(text1a, text2a, false, deadline)
      diffs_b = diff_main(text1b, text2b, false, deadline)

      diffs_a + diffs_b
    end

    # Split two texts into an array of strings.  Reduce the texts to a string
    # of hashes where each Unicode character represents one line.
    def diff_lines_to_chars(text1, text2)
      line_array = [""]  # e.g. line_array[4] == "Hello\n"
      line_hash = {}     # e.g. line_hash["Hello\n"] == 4

      [text1, text2].map do |text|
        # Split text into an array of strings.  Reduce the text to a string of
        # hashes where each Unicode character represents one line.
        chars = ""
        text.each_line do |line|
          if line_hash[line]
            chars += line_hash[line].chr(Encoding::UTF_8)
          else
            chars += line_array.length.chr(Encoding::UTF_8)
            line_hash[line] = line_array.length
            line_array << line
          end
        end
        chars
      end.push(line_array)
    end

    # Rehydrate the text in a diff from a string of line hashes to real lines of text.
    def diff_chars_to_lines(diffs, line_array)
      diffs.each do |diff|
        diff[1] = diff[1].chars.map { |c| line_array[c.ord] }.join
      end
    end

    # Determine the common prefix of two strings.
    def diff_common_prefix(text1, text2)
      # Quick check for common null cases.
      return 0 if text1.empty? || text2.empty? || text1[0] != text2[0]

      # Binary search.
      # Performance analysis: http://neil.fraser.name/news/2007/10/09/
      pointer_min   = 0
      pointer_max   = [text1.length, text2.length].min
      pointer_mid   = pointer_max
      pointer_start = 0

      while pointer_min < pointer_mid
        if text1[pointer_start...pointer_mid] == text2[pointer_start...pointer_mid]
          pointer_min   = pointer_mid
          pointer_start = pointer_min
        else
          pointer_max = pointer_mid
        end
        pointer_mid = (pointer_max - pointer_min) / 2 + pointer_min
      end

      pointer_mid
    end

    # Determine the common suffix of two strings.
    def diff_common_suffix(text1, text2)
      # Quick check for common null cases.
      return 0 if text1.empty? || text2.empty? || text1[-1] != text2[-1]

      # Binary search.
      # Performance analysis: http://neil.fraser.name/news/2007/10/09/
      pointer_min = 0
      pointer_max = [text1.length, text2.length].min
      pointer_mid = pointer_max
      pointer_end = 0

      while pointer_min < pointer_mid
        if text1[-pointer_mid..(-pointer_end - 1)] == text2[-pointer_mid..(-pointer_end - 1)]
          pointer_min = pointer_mid
          pointer_end = pointer_min
        else
          pointer_max = pointer_mid
        end
        pointer_mid = (pointer_max - pointer_min) / 2 + pointer_min
      end

      pointer_mid
    end

    # Determine if the suffix of one string is the prefix of another.
    def diff_common_overlap(text1, text2)
      # Cache the text lengths to prevent multiple calls.
      text1_length = text1.length
      text2_length = text2.length

      # Eliminate the null case.
      return 0 if text1_length.zero? || text2_length.zero?

      # Truncate the longer string.
      if text1_length > text2_length
        text1 = text1[-text2_length..-1]
      else
        text2 = text2[0...text1_length]
      end
      text_length = [text1_length, text2_length].min

      # Quick check for the whole case.
      return text_length if text1 == text2

      # Start by looking for a single character match
      # and increase length until no match is found.
      # Performance analysis: http://neil.fraser.name/news/2010/11/04/
      best   = 0
      length = 1
      loop do
        pattern = text1[(text_length - length)..-1]
        found   = text2.index(pattern)
        return best if found.nil?

        length += found
        if found.zero? || text1[(text_length - length)..-1] == text2[0..length]
          best = length
          length += 1
        end
      end
    end

    # Does a substring of short_text exist within long_text such that the
    # substring is at least half the length of long_text?
    def diff_half_match_index(long_text, short_text, index)
      seed             = long_text[index, long_text.length / 4]
      j                = -1
      best_common      = ""
      best_longtext_a  = nil
      best_longtext_b  = nil
      best_shorttext_a = nil
      best_shorttext_b = nil

      while (j = short_text.index(seed, j + 1))
        prefix_length = diff_common_prefix(long_text[index..-1], short_text[j..-1])
        suffix_length = diff_common_suffix(long_text[0...index], short_text[0...j])
        next unless best_common.length < suffix_length + prefix_length

        best_common      = "#{short_text[(j - suffix_length)...j]}#{short_text[j...(j + prefix_length)]}"
        best_longtext_a  = long_text[0...(index - suffix_length)]
        best_longtext_b  = long_text[(index + prefix_length)..-1]
        best_shorttext_a = short_text[0...(j - suffix_length)]
        best_shorttext_b = short_text[(j + prefix_length)..-1]
      end

      if best_common.length * 2 >= long_text.length
        [best_longtext_a, best_longtext_b, best_shorttext_a, best_shorttext_b, best_common]
      end
    end

    # Do the two texts share a substring which is at least half the length of the
    # longer text?
    # This speedup can produce non-minimal diffs.
    def diff_half_match(text1, text2)
      # Don't risk returning a non-optimal diff if we have unlimited time
      return nil if diff_timeout <= 0

      short_text, long_text = [text1, text2].sort_by(&:length)
      return if long_text.length < 4 || short_text.length * 2 < long_text.length # Pointless.

      # First check if the second quarter is the seed for a half-match.
      hm1 = diff_half_match_index(long_text, short_text, (long_text.length + 3) / 4)
      # Check again based on the third quarter.
      hm2 = diff_half_match_index(long_text, short_text, (long_text.length + 1) / 2)
      return if hm1.nil? && hm2.nil?

      hm =
        if hm2.nil? || hm1.nil?
          hm2 || hm1
        else # Both are present; select the longest.
          hm1[4].length > hm2[4].length ? hm1 : hm2
        end

      # A half-match was found, sort out the return data.
      if text1.length > text2.length
        text1_a, text1_b, text2_a, text2_b, mid_common = hm
      else
        text2_a, text2_b, text1_a, text1_b, mid_common = hm
      end

      [text1_a, text1_b, text2_a, text2_b, mid_common]
    end

    # Reduce the number of edits by eliminating semantically trivial equalities.
    def diff_cleanup_semantic(diffs)
      changes            = false
      equalities         = []  # Stack of indices where equalities are found.
      last_equality      = nil # Always equal to equalities.last[1]
      pointer            = 0   # Index of current position.
      # Number of characters that changed prior to the equality.
      length_insertions1 = 0
      length_deletions1  = 0
      # Number of characters that changed after the equality.
      length_insertions2 = 0
      length_deletions2  = 0

      while pointer < diffs.length
        if diffs[pointer].is_equal? # Equality found.
          length_insertions1 = length_insertions2
          length_deletions1  = length_deletions2
          length_insertions2 = 0
          length_deletions2  = 0
          last_equality      = diffs[pointer].text
          equalities << pointer
        else # An insertion or deletion.
          if diffs[pointer].is_insert?
            length_insertions2 += diffs[pointer].text.length
          else
            length_deletions2 += diffs[pointer].text.length
          end

          maximum_min_length = [
            [length_insertions1, length_deletions1].max,
            [length_insertions2, length_deletions2].max
          ].min

          if !last_equality.nil? && last_equality.length <= maximum_min_length
            diffs[equalities.last, 0] = [new_delete_node(last_equality)] # Duplicate record.
            diffs[equalities.last + 1].as_insert!                      # Change second copy to insert.
            equalities.pop(2)                                          # Throw away the equality we just deleted.
            pointer = equalities.last || -1

            # Reset the counters.
            length_insertions1 = 0
            length_deletions1  = 0
            length_insertions2 = 0
            length_deletions2  = 0
            last_equality      = nil
            changes            = true
          end
        end
        pointer += 1
      end

      # Normalize the diff.
      diff_cleanup_merge(diffs) if changes
      diff_cleanup_semantic_lossless(diffs)

      # Find any overlaps between deletions and insertions.
      # e.g: <del>abcxxx</del><ins>xxxdef</ins>
      #   -> <del>abc</del>xxx<ins>def</ins>
      # e.g: <del>xxxabc</del><ins>defxxx</ins>
      #   -> <ins>def</ins>xxx<del>abc</del>
      # Only extract an overlap if it is as big as the edit ahead or behind it.
      pointer = 1
      while pointer < diffs.length
        if diffs[pointer - 1].is_delete? && diffs[pointer].is_insert?
          deletion        = diffs[pointer - 1].text
          insertion       = diffs[pointer].text
          overlap_length1 = diff_common_overlap(deletion, insertion)
          overlap_length2 = diff_common_overlap(insertion, deletion)
          if overlap_length1 >= overlap_length2 && (overlap_length1 >= deletion.length / 2.0 || overlap_length1 >= insertion.length / 2.0)
            # Overlap found.  Insert an equality and trim the surrounding edits.
            diffs[pointer, 0]  = [new_equal_node(insertion[0...overlap_length1])]
            diffs[pointer - 1] = new_delete_node(deletion[0...-overlap_length1])
            diffs[pointer + 1] = new_insert_node(insertion[overlap_length1..-1])
            pointer += 1
          elsif overlap_length2 >= deletion.length / 2.0 || overlap_length2 >= insertion.length / 2.0
            diffs[pointer, 0]  = [new_equal_node(deletion[0...overlap_length2])]
            diffs[pointer - 1] = new_insert_node(insertion[0...-overlap_length2])
            diffs[pointer + 1] = new_delete_node(deletion[overlap_length2..-1])
            pointer += 1
          end
          pointer += 1
        end
        pointer += 1
      end
    end

    # Given two strings, compute a score representing whether the
    # internal boundary falls on logical boundaries.
    # Scores range from 5 (best) to 0 (worst).
    def diff_cleanup_semantic_score(one, two)
      return 5 if one.empty? || two.empty? # Edges are the best.

      # Define some regex patterns for matching boundaries.
      one_char           = one[-1]
      two_char           = two[0]
      score              = 0
      non_word_character = /[^[:alnum:]]/
      whitespace         = /[[:space:]]/
      linebreak          = /[[:cntrl:]]/
      line_end           = /\n\r?\n$/
      line_start         = /^\r?\n\r?\n/

      # Each port of this function behaves slightly differently due to
      # subtle differences in each language's definition of things like
      # 'whitespace'.  Since this function's purpose is largely cosmetic,
      # the choice has been made to use each language's native features
      # rather than force total conformity.
      # One point for non-alphanumeric.
      if one_char =~ non_word_character || two_char =~ non_word_character
        score += 1
        # Two points for whitespace.
        if one_char =~ whitespace || two_char =~ whitespace
          score += 1
          # Three points for line breaks.
          if one_char =~ linebreak || two_char =~ linebreak
            score += 1
            # Four points for blank lines.
            if one =~ line_end || two =~ line_start
              score += 1
            end
          end
        end
      end

      score
    end

    # Look for single edits surrounded on both sides by equalities
    # which can be shifted sideways to align the edit to a word boundary.
    # e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
    def diff_cleanup_semantic_lossless(diffs)
      pointer = 1
      # Intentionally ignore the first and last element (don't need checking).
      while pointer < diffs.length - 1
        if diffs[pointer - 1].is_equal? && diffs[pointer + 1].is_equal?
          # This is a single edit surrounded by equalities.
          equality1 = diffs[pointer - 1].text
          edit      = diffs[pointer].text
          equality2 = diffs[pointer + 1].text

          # First, shift the edit as far left as possible.
          common_offset = diff_common_suffix(equality1, edit)
          if common_offset.nonzero?
            common_string = edit[-common_offset..-1]
            equality1     = equality1[0...-common_offset]
            edit          = common_string + edit[0...-common_offset]
            equality2     = common_string + equality2
          end

          # Second, step character by character right, looking for the best fit.
          best_equality1 = equality1
          best_edit      = edit
          best_equality2 = equality2
          best_score     = diff_cleanup_semantic_score(equality1, edit) + diff_cleanup_semantic_score(edit, equality2)

          while edit[0] == equality2[0]
            equality1 += edit[0]
            edit      = edit[1..-1] + equality2[0]
            equality2 = equality2[1..-1]
            score     = diff_cleanup_semantic_score(equality1, edit) + diff_cleanup_semantic_score(edit, equality2)
            next unless score >= best_score # The >= encourages trailing rather than leading whitespace on edits.

            best_score     = score
            best_equality1 = equality1
            best_edit      = edit
            best_equality2 = equality2
          end

          if diffs[pointer - 1].text != best_equality1
            # We have an improvement, save it back to the diff.
            if best_equality1.empty?
              diffs[pointer - 1, 1] = []
              pointer -= 1
            else
              diffs[pointer - 1].text = best_equality1
            end

            diffs[pointer].text = best_edit

            if best_equality2.empty?
              diffs[pointer + 1, 1] = []
              pointer -= 1
            else
              diffs[pointer + 1].text = best_equality2
            end
          end
        end

        pointer += 1
      end
    end

    # Reduce the number of edits by eliminating operationally trivial equalities.
    def diff_cleanup_efficiency(diffs)
      changes       = false # flag used to know if we changed the diffs and need to run `diff_cleanup_merge`
      equalities    = []    # Stack of indices where equalities are found.
      last_equality = ""    # Always equal to equalities.last[1]
      pointer       = 0     # Index of current position.
      pre_ins       = false # Is there an insertion operation before the last equality.
      pre_del       = false # Is there a deletion operation before the last equality.
      post_ins      = false # Is there an insertion operation after the last equality.
      post_del      = false # Is there a deletion operation after the last equality.

      while pointer < diffs.length
        if diffs[pointer].is_equal? # Equality found.
          if diffs[pointer].text.length < diff_edit_cost && (post_ins || post_del)
            # Candidate found.
            pre_ins       = post_ins
            pre_del       = post_del
            last_equality = diffs[pointer].text
            equalities << pointer
          else
            # Not a candidate, and can never become one.
            equalities.clear
            last_equality = ""
          end
          post_ins = false
          post_del = false
        else # An insertion or deletion.
          if diffs[pointer].is_delete?
            post_del = true
          else
            post_ins = true
          end

          # Five types to be split:
          # <ins>A</ins><del>B</del>XY<ins>C</ins><del>D</del>
          # <ins>A</ins>X<ins>C</ins><del>D</del>
          # <ins>A</ins><del>B</del>X<ins>C</ins>
          # <ins>A</del>X<ins>C</ins><del>D</del>
          # <ins>A</ins><del>B</del>X<del>C</del>
          pre_post_count = [pre_ins, pre_del, post_ins, post_del].count(true)

          if !last_equality.empty? && (pre_post_count == 4 || ((last_equality.length < diff_edit_cost / 2) && pre_post_count == 3))
            diffs[equalities.last, 0] = [new_delete_node(last_equality)] # Duplicate record.
            diffs[equalities.last + 1].as_insert!                        # Change second copy to insert.
            equalities.pop                                               # Throw away the equality we just deleted
            last_equality = ""
            if pre_ins && pre_del
              # No changes made which could affect previous entry, keep going.
              post_ins = true
              post_del = true
              equalities.clear
            else
              unless equalities.empty?
                equalities.pop # Throw away the previous equality.
                pointer = equalities.last || -1
              end
              post_ins = false
              post_del = false
            end
            changes = true
          end
        end
        pointer += 1
      end

      diff_cleanup_merge(diffs) if changes
    end

    # Reorder and merge like edit sections.  Merge equalities.
    # Any edit section can move as long as it doesn't cross an equality.
    def diff_cleanup_merge(diffs)
      diffs << new_equal_node("") # Add a dummy entry at the end.
      pointer      = 0
      count_delete = 0
      count_insert = 0
      text_delete  = ""
      text_insert  = ""

      while pointer < diffs.length
        case diffs[pointer].operation
        when :INSERT
          text_insert  += diffs[pointer].text
          pointer      += 1
          count_insert += 1
        when :DELETE
          text_delete  += diffs[pointer].text
          count_delete += 1
          pointer      += 1
        else # :EQUAL
          # Upon reaching an equality, check for prior redundancies.
          if count_delete + count_insert > 1
            if count_delete.nonzero? && count_insert.nonzero?
              # Factor out any common prefixies.
              common_length = diff_common_prefix(text_insert, text_delete)
              if common_length.nonzero?
                position = pointer - count_delete - count_insert
                if position.positive? && diffs[position - 1].is_equal?
                  diffs[position - 1].text += text_insert[0...common_length]
                else
                  diffs.unshift(new_equal_node(text_insert[0...common_length]))
                  pointer += 1
                end
                text_insert = text_insert[common_length..-1]
                text_delete = text_delete[common_length..-1]
              end
              # Factor out any common suffixies.
              common_length = diff_common_suffix(text_insert, text_delete)
              if common_length.nonzero?
                diffs[pointer].text =  text_insert[-common_length..-1] + diffs[pointer].text
                text_insert         = text_insert[0...-common_length]
                text_delete         = text_delete[0...-common_length]
              end
            end

            # Delete the offending records and add the merged ones.
            position = pointer - count_delete - count_insert
            diffs[position, count_delete + count_insert] =
              if count_delete.zero?
                [new_insert_node(text_insert)]
              elsif count_insert.zero?
                [new_delete_node(text_delete)]
              else
                [new_delete_node(text_delete), new_insert_node(text_insert)]
              end

            pointer = position + (count_delete.zero? ? 0 : 1) + (count_insert.zero? ? 0 : 1) + 1
          elsif pointer.positive? && diffs[pointer - 1].is_equal?
            # Merge this equality with the previous one.
            diffs[pointer - 1].text += diffs[pointer].text
            diffs[pointer, 1] = []
          else
            pointer += 1
          end
          count_insert = 0
          count_delete = 0
          text_delete  = ""
          text_insert  = ""
        end
      end

      diffs.pop if diffs.last.text.empty? # Remove the dummy entry at the end.

      # Second pass: look for single edits surrounded on both sides by equalities
      # which can be shifted sideways to eliminate an equality.
      # e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
      changes = false
      pointer = 1

      # Intentionally ignore the first and last element (don't need checking).
      while pointer < diffs.length - 1
        if diffs[pointer - 1].is_equal? && diffs[pointer + 1].is_equal?
          # This is a single edit surrounded by equalities.
          if diffs[pointer].text[-diffs[pointer - 1].text.length..-1] == diffs[pointer - 1].text
            # Shift the edit over the previous equality.
            changes                  = true
            diffs[pointer].text      = diffs[pointer - 1].text + diffs[pointer].text[0...-diffs[pointer - 1].text.length]
            diffs[pointer + 1].text  = diffs[pointer - 1].text + diffs[pointer + 1].text
            diffs[pointer - 1, 1]    = []
          elsif diffs[pointer].text[0...diffs[pointer + 1].text.length] == diffs[pointer + 1].text
            # Shift the edit over the next equality.
            changes = true
            diffs[pointer - 1].text += diffs[pointer + 1].text
            diffs[pointer].text     = diffs[pointer].text[diffs[pointer + 1].text.length..-1] + diffs[pointer + 1].text
            diffs[pointer + 1, 1]   = []
          end
        end
        pointer += 1
      end

      # If shifts were made, the diff needs reordering and another shift sweep.
      diff_cleanup_merge(diffs) if changes
    end

    # Convert a diff array into a pretty HTML report.
    def diff_pretty_html(diffs)
      diffs.map do |diff|
        text = diff.text.tr("&", "&amp;").tr("<", "&lt;").tr(">", "&gt;").tr("\n", "&para;<br>")

        case diff.operation
        when :INSERT
          "<ins style=\"background:#e6ffe6;\">#{text}</ins>"
        when :DELETE
          "<del style=\"background:#ffe6e6;\">#{text}</del>"
        else #:EQUAL
          "<span>#{text}</span>"
        end
      end.join
    end

    # Compute and return the source text (all equalities and deletions).
    def diff_text1(diffs)
      diffs.map { |diff| diff.is_insert? ? "" : diff.text }.join
    end

    # Compute and return the destination text (all equalities and insertions).
    def diff_text2(diffs)
      diffs.map { |diff| diff.is_delete? ? "" : diff.text }.join
    end

    # Compute the Levenshtein distance; the number of inserted, deleted or
    # substituted characters.
    def diff_levenshtein(diffs)
      levenshtein = 0
      insertions  = 0
      deletions   = 0

      diffs.each do |diff|
        case diff.operation
        when :INSERT
          insertions += diff.text.length
        when :DELETE
          deletions += diff.text.length
        else # equal
          # A deletion and an insertion is one substitution.
          levenshtein += [insertions, deletions].max
          insertions  = 0
          deletions   = 0
        end
      end

      levenshtein + [insertions, deletions].max
    end

    # Crush the diff into an encoded string which describes the operations
    # required to transform text1 into text2.
    # E.g. =3\t-2\t+ing  -> Keep 3 chars, delete 2 chars, insert 'ing'.
    # Operations are tab-separated.  Inserted text is escaped using %xx notation.
    def diff_to_delta(diffs)
      diffs.map do |diff|
        case diff.operation
        when :INSERT
          "+#{URI.encode(diff.text, %r{[^0-9A-Za-z_.;!~*'(),\/?:@&=+$#-]})}"
        when :DELETE
          "-#{diff.text.length}"
        else # equal
          "=#{diff.text.length}"
        end
      end.join("\t").tr("%20", " ")
    end

    private

    def new_delete_node(text)
      Diff::Node.new(:DELETE, text)
    end

    def new_insert_node(text)
      Diff::Node.new(:INSERT, text)
    end

    def new_equal_node(text)
      Diff::Node.new(:EQUAL, text)
    end
  end
end
# rubocop:enable Metrics/BlockNesting
