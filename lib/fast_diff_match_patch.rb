# frozen_string_literal: true

require "fast_diff_match_patch/version"
require "fast_diff_match_patch/diff_node"
require "fast_diff_match_patch/fast_diff_match_patch" # C extension

# rubocop:disable Metrics/BlockNesting
class FastDiffMatchPatch
  attr_accessor :diff_timeout, :diff_edit_cost
  attr_accessor :match_threshold, :match_distance
  attr_accessor :patch_delete_threshold, :patch_margin
  attr_reader   :match_max_bits

  # Init's a diff_match_patch object with default settings.
  # Redefine these in your program to override the defaults.
  def initialize(**options)
    # Number of seconds to map a diff before giving up (0 for infinity).
    @diff_timeout           = options.delete(:diff_timeout)           || 1
    # Cost of an empty edit operation in terms of edit characters.
    @diff_edit_cost         = options.delete(:diff_edit_cost)         || 4
    # At what point is no match declared (0.0 = perfection, 1.0 = very loose).
    @match_threshold        = options.delete(:match_threshold)        || 0.5
    # How far to search for a match (0 = exact location, 1000+ = broad match).
    # A match this many characters away from the expected location will add
    # 1.0 to the score (0.0 is a perfect match).
    @match_distance         = options.delete(:match_distance)         || 1000
    # When deleting a large block of text (over ~64 characters), how close does
    # the contents have to match the expected contents. (0.0 = perfection,
    # 1.0 = very loose).  Note that Match_Threshold controls how closely the
    # end points of a delete need to match.
    @patch_delete_threshold = options.delete(:patch_delete_threshold) || 0.5
    # Chunk size for context length.
    @patch_margin           = options.delete(:patch_margin)           || 4

    # The number of bits in an int.
    @match_max_bits = 32
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
    diff_cleanup_merge(diffs)

    diffs
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
      diffs << DiffNode.new(operation, long_text[0...sub_index])
      diffs << new_equal_node(short_text)
      diffs << DiffNode.new(operation, long_text[(sub_index + short_text.length)..-1])

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

    diff_bisect(text1, text2, deadline) # C Extention call
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

    encoded_strings = [text1, text2].map do |text|
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
    end

    encoded_strings << line_array
  end

  # Rehydrate the text in a diff from a string of line hashes to real lines of text.
  def diff_chars_to_lines(diffs, line_array)
    diffs.each do |diff|
      diff.text = diff.text.chars.map { |c| line_array[c.ord] }.join
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
          diffs[equalities.last + 1].to_insert!                      # Change second copy to insert.
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
          diffs[equalities.last + 1].to_insert!                        # Change second copy to insert.
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
    diffs.map { |diff| diff.text2_change? ? "" : diff.text }.join
  end

  # Compute and return the destination text (all equalities and insertions).
  def diff_text2(diffs)
    diffs.map { |diff| diff.text1_change? ? "" : diff.text }.join
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

  def diff_index(diffs, loc)
    chars1      = 0
    chars2      = 0
    last_chars1 = 0
    last_chars2 = 0

    idx = diffs.index do |diff|
      chars1 += diff.text.length unless diff.is_insert?
      chars2 += diff.text.length unless diff.is_delete?
      next true if chars1 > loc

      last_chars1 = chars1
      last_chars2 = chars2
      false
    end

    if diffs.length != idx && diffs[idx].is_delete?
      last_chars2
    else
      last_chars2 + (loc - last_chars1)
    end
  end

  def match_main(text, pattern, loc)
    if text.nil? || pattern.nil? || loc.nil?
      raise ArgumentError.new("Null input. (match_main)")
    end

    loc = [0, [loc, text.length].min].max
    return 0   if text == pattern
    return -1  if text.empty?
    return loc if text[loc, pattern.length] == pattern

    match_bitap(text, pattern, loc) # C extension
  end

  def patch_make(*args)
    text1, diffs   = patch_arguments(*args)
    patch          = TempPatch.new
    patches        = []
    char_count1    = 0
    char_count2    = 0
    prepatch_text  = text1
    postpatch_text = text1
    return [] if diffs.empty?

    diffs.each.with_index do |diff, idx|
      if patch.diffs.empty? && !diff.is_equal?
        patch.start1 = char_count1
        patch.start2 = char_count2
      end

      case diff.operation
      when :INSERT
        patch.diffs << diff
        patch.length2 += diff.text.length
        postpatch_text = postpatch_text[0...char_count2] + diff.text +
                         postpatch_text[char_count2..-1]
      when :DELETE
        patch.length1 += diff.text.length
        patch.diffs << diff
        postpatch_text = postpatch_text[0...char_count2] +
                         postpatch_text[(char_count2 + diff.text.length)..-1]
      else # :EQUAL
        if diff.text.length <= 2 * @patch_margin && !patch.diffs.empty? && diffs.length != (idx + 1)
          patch.diffs << diff
          patch.length1 += diff.text.length
          patch.length2 += diff.text.length
        elsif diff.text.length >= 2 * @patch_margin
          unless patch.diffs.empty?
            patch_add_context(patch, prepatch_text)
            patches << patch
            patch         = TempPatch.new
            prepatch_text = postpatch_text
            char_count1   = char_count2
          end
        end
      end

      char_count1 += diff.text.length unless diff.is_insert?
      char_count2 += diff.text.length unless diff.is_delete?
    end

    unless patch.diffs.empty?
      patch_add_context(patch, prepatch_text)
      patches << patch
    end

    patches
  end
  alias patch_main patch_make

  # Take a list of patches and return a textual representation
  def patch_to_text(patches)
    patches.join
  end

  def patch_from_text(input)
    return [] if input.empty?

    patches = []
    text    = input.split("\n")
    text_pointer = 0
    patch_header = /^@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@$/
    while text_pointer < text.length
      m = text[text_pointer].match(patch_header)
      if m.nil?
        raise ArgumentError.new("Invalid patch string: #{text[text_pointer]}")
      end

      patch = TempPatch.new
      patches << patch
      patch.start1 = m[1].to_i
      if m[2].empty?
        patch.start1 -= 1
        patch.length1 = 1
      elsif m[2] == "0"
        patch.length1 = 0
      else
        patch.start1 -= 1
        patch.length1 = m[2].to_i
      end

      patch.start2 = m[3].to_i
      if m[4].empty?
        patch.start2 -= 1
        patch.length2 = 1
      elsif m[4] == "0"
        patch.length2 = 0
      else
        patch.start2 -= 1
        patch.length2 = m[4].to_i
      end

      text_pointer += 1
      while text_pointer < text.length
        if text[text_pointer].empty?
          text_pointer += 1
          next
        end

        sign = text[text_pointer][0]
        line = URI.decode(text[text_pointer][1..-1].force_encoding(Encoding::UTF_8))

        case sign
        when "-"
          patch.diffs << new_delete_node(line)
        when "+"
          patch.diffs << new_insert_node(line)
        when " "
          patch.diffs << new_equal_node(line)
        when "@"
          break
        else
          raise ArgumentError.new("Invalid patch mode \"#{sign}\" in: #{line}")
        end

        text_pointer += 1
      end
    end

    patches
  end

  def patch_add_context(patch, text)
    return if text.empty?

    padding            = 0
    pattern            = text[patch.start2, patch.length1]
    max_pattern_length = @match_max_bits - 2 * @patch_margin

    while text.index(pattern) != text.rindex(pattern) && pattern.length < max_pattern_length
      padding += @patch_margin
      pattern = text[[0, patch.start2 - padding].max...(patch.start2 + patch.length1 + padding)]
    end

    # Add one chunk for good luck.
    padding += @patch_margin

    # Add the prefix.
    prefix = text[[0, patch.start2 - padding].max...patch.start2]
    patch.diffs.unshift(new_equal_node(prefix)) unless prefix.to_s.empty?

    # Add the suffix.
    suffix = text[patch.start2 + patch.length1, padding]
    patch.diffs << new_equal_node(suffix) unless suffix.to_s.empty?

    # Roll back the start points.
    patch.start1 -= prefix.length
    patch.start2 -= prefix.length

    # Extend the lengths.
    patch.length1 += prefix.length + suffix.length
    patch.length2 += prefix.length + suffix.length
  end

  def patch_add_padding(patches)
    padding_length = @patch_margin
    null_padding   = (1..padding_length).map { |x| x.chr(Encoding::UTF_8) }.join

    patches.each do |patch|
      patch.start1 += padding_length
      patch.start2 += padding_length
    end

    # Add some padding on start of first diff
    patch = patches.first
    diffs = patch.diffs
    if diffs.empty? || !diffs.first.is_equal?
      # Add null_padding equality
      diffs.unshift(new_equal_node(null_padding))
      patch.start1  -= padding_length
      patch.start2  -= padding_length
      patch.length1 += padding_length
      patch.length2 += padding_length
    elsif padding_length > diffs.first.text.length
      # Grow first equality
      extra_length = padding_length - diffs.first.text.length
      diffs.first.text = null_padding[diffs.first.text.length..-1] + diffs.first.text
      patch.start1  -= extra_length
      patch.start2  -= extra_length
      patch.length1 += extra_length
      patch.length2 += extra_length
    end

    # Add padding on the end of last diff
    patch = patches.last
    diffs = patch.diffs

    if diffs.empty? || !diffs.last.is_equal?
      diffs << new_equal_node(null_padding)
      patch.length1 += padding_length
      patch.length2 += padding_length
    elsif padding_length > diffs.last.text.length
      # Grow last equality
      extra_length = padding_length - diffs.last.text.length
      diffs.last.text += null_padding[0, extra_length]
      patch.length1   += extra_length
      patch.length2   += extra_length
    end

    null_padding
  end

  # Look through the patches and break up any which are longer than the
  # maximum limit of the match algorithm.
  def patch_split_max(patches)
    patch_size = match_max_bits

    x = 0
    while x < patches.length
      if patches[x].length1 > patch_size
        big_patch = patches[x]
        # Remove the big old patch
        patches[x, 1] = []
        x -= 1
        start1 = big_patch.start1
        start2 = big_patch.start2
        pre_context = ""
        until big_patch.diffs.empty?
          # Create one of several smaller patches.
          patch = TempPatch.new
          empty = true
          patch.start1 = start1 - pre_context.length
          patch.start2 = start2 - pre_context.length
          unless pre_context.empty?
            patch.length1 = patch.length2 = pre_context.length
            patch.diffs.push(new_equal_node(pre_context))
          end

          while !big_patch.diffs.empty? && patch.length1 < patch_size - patch_margin
            diff = big_patch.diffs.first
            if diff.is_insert?
              # Insertions are harmless.
              patch.length2 += diff.text.length
              start2 += diff.text.length
              patch.diffs.push(big_patch.diffs.shift)
              empty = false
            elsif diff.is_delete? && patch.diffs.length == 1 &&
                  patch.diffs.first.is_equal? && diff[1].length > 2 * patch_size
              # This is a large deletion.  Let it pass in one chunk.
              patch.length1 += diff.text.length
              start1 += diff.text.length
              empty = false
              patch.diffs.push(big_patch.diffs.shift)
            else
              # Deletion or equality.  Only take as much as we can stomach.
              diff_text = diff.text[0, patch_size - patch.length1 - patch_margin]
              patch.length1 += diff_text.length
              start1        += diff_text.length
              if diff.is_equal?
                patch.length2 += diff_text.length
                start2 += diff_text.length
              else
                empty = false
              end
              patch.diffs.push(DiffNode.new(diff.operation, diff_text))
              if diff_text == big_patch.diffs.first.text
                big_patch.diffs.shift
              else
                big_patch.diffs.first.text = big_patch.diffs.first.text[diff_text.length..-1]
              end
            end
          end

          # Compute the head context for the next patch.
          pre_context = diff_text2(patch.diffs)[-patch_margin..-1] || ""

          # Append the end context for this patch.
          post_context = diff_text1(big_patch.diffs)[0...patch_margin] || ""
          unless post_context.empty?
            patch.length1 += post_context.length
            patch.length2 += post_context.length
            if !patch.diffs.empty? && patch.diffs.last.is_equal?
              patch.diffs.last.text += post_context
            else
              patch.diffs.push(new_equal_node(post_context))
            end
          end
          unless empty
            x += 1
            patches[x, 0] = [patch]
          end
        end
      end
      x += 1
    end
  end

  def patch_apply(patches, text)
    return [text, []] if patches.empty?

    patches      = Marshal.load(Marshal.dump(patches)) # Deep copy patches to prevent outside mutation
    null_padding = patch_add_padding(patches)
    text         = null_padding + text + null_padding
    delta        = 0
    results      = []
    patch_split_max(patches)

    patches.each.with_index do |patch, idx|
      expected_loc = patch.start2 + delta
      text1        = diff_text1(patch.diffs)
      end_loc      = -1

      if text1.length > @match_max_bits
        start_loc = match_main(text, text1[0, @match_max_bits], expected_loc)

        unless start_loc.negative?
          end_loc   = match_main(text, text1[(text1.length - @match_max_bits)..-1], expected_loc + text1.length - @match_max_bits)
          start_loc = -1 if end_loc.negative? || start_loc >= end_loc
        end
      else
        start_loc = match_main(text, text1, expected_loc)
      end

      if start_loc.negative?
        # no match found
        results[idx] = false
        # Subtract the delta for this failed patch from subsequent patches.
        delta -= patch.length2 - patch.length1
      else
        # match found
        results[idx] = true
        delta        = start_loc - expected_loc
        text2        = text[start_loc, end_loc.negative? ? text1.length : end_loc + @match_max_bits]

        if text1 == text2
          # Perfect match, just shove the replacement text in.
          text = text[0, start_loc] + diff_text2(patch.diffs) + text[(start_loc + text1.length)..-1]
        else
          # Imperfect match.
          # Run a diff to get a framework of equivalent indices.
          diffs = diff_main(text1, text2, false)
          if text1.length > @match_max_bits && (diff_levenshtein(diffs).to_f / text1.length) > @patch_delete_threshold
            results[idx] = false
          else
            diff_cleanup_semantic_lossless(diffs)
            index1 = 0
            index2 = 0
            patch.diffs.each do |diff|
              index2 = diff_index(diffs, index1) unless diff.is_equal?
              if diff.is_insert?
                text = text[0, start_loc + index2] + diff.text + text[(start_loc + index2)..-1]
              elsif diff.is_delete?
                text = text[0, start_loc + index2] + text[(start_loc + diff_index(diffs, index1 + diff.text.length))..-1]
              end

              index1 += diff.text.length unless diff.is_delete?
            end
          end
        end
      end
    end

    text = text[null_padding.length...-null_padding.length]
    [text, results]
  end

  private

  def new_delete_node(text)
    DiffNode.new(:DELETE, text)
  end

  def new_insert_node(text)
    DiffNode.new(:INSERT, text)
  end

  def new_equal_node(text)
    DiffNode.new(:EQUAL, text)
  end

  def patch_arguments(*args)
    if args.length == 1 && args[0].is_a?(Array)
      diffs = args[0]
      text1 = diff_text1(diffs)
    elsif args.length == 2 && args[0].is_a?(String) && args[1].is_a?(String)
      text1 = args[0]
      text2 = args[1]
      diffs = diff_main(text1, text2, true)
      if diffs.length > 2
        diff_cleanup_semantic(diffs)
        diff_cleanup_efficiency(diffs)
      end
    elsif args.length == 2 && args[0].is_a?(String) && args[1].is_a?(Array)
      text1 = args[0]
      diffs = args[1]
    elsif args.length == 3 && args[0].is_a?(String) && args[1].is_a?(String) && args[2].is_a?(Array)
      text1 = args[0]
      # text2 (args[1]) is not used
      diffs = args[2]
    else
      raise ArgumentError.new("Unknown argument list types.")
    end

    [text1, diffs]
  end
end
# rubocop:enable Metrics/BlockNesting
