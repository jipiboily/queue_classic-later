require 'spec_helper'

describe QC::Later do
  describe ".tick" do
    it "enqueue moves the pending jobs to queue classic" do
      QC.enqueue_in(0, "Kernel.puts", "hello world")
      described_class.tick
      QC.count.should == 1
    end

    context "with custom columns" do
      before do
        QC::Conn.execute("ALTER TABLE queue_classic_jobs ADD retries INTEGER")
        QC::Conn.execute("ALTER TABLE queue_classic_later_jobs ADD retries INTEGER")
      end

      after do
        QC::Conn.execute("ALTER TABLE queue_classic_jobs DROP COLUMN retries")
        QC::Conn.execute("ALTER TABLE queue_classic_later_jobs DROP COLUMN retries")
      end

      it "copies the value over" do
        QC.enqueue_in_with_custom(0, "Kernel.puts", {retries: 1}, "hello world")
        described_class.tick
        QC.count.should == 1
      end

      it "works with ijnl" do
        QC.enqueue_in_with_custom(0, "Kernel.puts", {retries: nil}, "hello world")
        described_class.tick
        QC.count.should == 1
      end
    end
  end
end
