# The stand-in for examples/game.mrb until the two-board game is committed:
# prints "hello game" once a second, to try the console's
# ［対戦ゲームを実機の app.mrb にする］ with. Built with the firmware's compiler:
#   docker compose -f docker/compose.yml run --rm shell \
#     bash -lc "rake && build/host/bin/mrbc -o examples/game.mrb tools/game-mrb/hello_game.rb"
while true
  puts "hello game"
  sleep_ms 1000
end
