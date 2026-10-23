-- A tail call hides this frame, so service.root cannot tell it apart from
-- the script being run; it still fails because the script returns no handler.
return require "service.root"
