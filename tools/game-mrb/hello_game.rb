# A stand-in for examples/game.mrb: prints "hello game" once a second.
# tools/browser-check/lib-update-check.cjs hands its .mrb (hello_game.mrb,
# beside this) to the page as examples/game.mrb, to try the console's
# ［対戦ゲームを実機の app.mrb にする］ with; copying it to examples/game.mrb
# tries the button on a board. Built with the firmware's compiler:
#   docker compose -f docker/compose.yml run --rm shell \
#     bash -lc "rake && build/host/bin/mrbc -o tools/game-mrb/hello_game.mrb tools/game-mrb/hello_game.rb"
while true
  puts "hello game"
  sleep_ms 1000
end
