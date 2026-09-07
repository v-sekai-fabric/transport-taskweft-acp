# Mint.WebSocket.new/4 shows no ok branch in its success typing under OTP 29, so
# Dialyzer reads the upgrade as impossible; test/executor_socket_test.exs completes it.
[
  {"lib/taskweft_acp/executor/socket.ex", :pattern_match, 62},
  {"lib/taskweft_acp/executor/socket.ex", :pattern_match, 206}
]
