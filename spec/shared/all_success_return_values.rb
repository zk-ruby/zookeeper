shared_examples_for "all success return values" do
  it %[should have a return code of Zookeeper::ZOK] do
    expect(@rv[:rc]).to eq(Zookeeper::ZOK)
  end

  it %[should have a req_id integer] do
    expect(@rv[:req_id]).to be_kind_of(Integer)
  end
end

