require 'spec_helper'

describe 'Compatibiliy layer' do
  it %[should raise the correct error when a const is missing] do
    lambda { Zookeeper::THISISANINVALIDCONST }.should raise_error(NameError)
  end
end

