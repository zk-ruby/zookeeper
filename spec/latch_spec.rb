require 'spec_helper'

# this is a simple sanity check of my timeout addition

describe Zookeeper::Latch do
  subject { described_class.new }

  describe %[await] do
    describe %[with timeout] do
      it %[should return after waiting until timeout if not released] do
        other_latch = described_class.new

        th = Thread.new do
          subject.await(0.01)
          other_latch.release
        end

        other_latch.await
        expect(th.join(1)).to eq(th)
      end
    end
  end
end

