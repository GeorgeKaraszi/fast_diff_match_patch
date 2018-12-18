[![Build Status](https://travis-ci.com/GeorgeKaraszi/fast_diff_match_patch.svg?branch=master)](https://travis-ci.com/GeorgeKaraszi/fast_diff_match_patch)

# FastDiffMatchPatch

Faster implementation of Google's Diff Match Patch: https://github.com/google/diff-match-patch

Performance comparation:



|Language        |Version       |Seconds|
|----------------|--------------|--------|
|Objective-C     |Xcode 9.2     | 0.117  |
|**Ruby**        |2.4.6         | **0.165**  |
|C#	Mono         |5.4.1         | 0.214  |
|Java            |1.8.0         | 0.272  |
|JS (Firefox)    |58.0.2        | 0.830  |
|PyPy3           |5.10.1	    | 1.036  |
|JS (Chrome)     |64.0.3282.140 | 1.388  |
|Dart (JS Chrome)|64.0.3282.140 | 1.604  |
|Dart (VM)       |1.24.3        | 1.705  |
|Lua             |5.3.4         | 13.998 |
|Python 2.7      |2.7.10	    | 16.810 |
|Python 3.5	     |3.5.1         | 28.371 |
```

FastDiffMatchPatch:
|Ruby

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fast_diff_match_patch'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fast_diff_match_patch
