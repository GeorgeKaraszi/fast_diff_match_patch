# frozen_string_literal: true

module FastDiffMatchPatch
  RSpec.describe "Speed Test" do
    let!(:dmp)    { Diff.new }
    let!(:file_a) { File.read("spec/fixtures/speed1.txt") }
    let!(:file_b) { File.read("spec/fixtures/speed2.txt") }

    it "should complete extremely fast" do
      t1 = Time.now
      dmp.diff_main(file_a, file_b)
      t2 = Time.now

      puts "Completed in: #{t2 - t1}"
      expect(t2 - t1).to be_between(0, 0.5)
    end
  end
end
