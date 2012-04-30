shared_examples_for "all success return values" do
  it %[should have a return code of Zookeeper::ZOK] do
    @rv[:rc].should == Zookeeper::ZOK
  end

  it %[should have a req_id integer] do
    @rv[:req_id].should be_kind_of(Integer)
  end
end

