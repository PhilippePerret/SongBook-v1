# frozen_string_literal: true

# État du REPL (`songbook -i`) — chanson/carnet "courants" fixés par `use song|s "titre"`
# / `use songbook|sb "titre"` (voir `CLI`), consultés par les commandes qui prennent un
# titre chanson/carnet quand aucun titre explicite n'est donné. Vit UNIQUEMENT en mémoire
# process : sans effet hors REPL (une invocation `songbook ...` normale se termine avant
# qu'un `use` ait pu être tapé).
module Session
  class << self
    attr_accessor :song, :carnet
  end

  # Contexte chanson pour LA SEULE durée du bloc — voir `--song TITRE` (CLI) : même
  # rôle que `use song`, mais SANS PERSISTANCE (restauré même si le bloc `abort`/lève).
  def self.with_song(folder)
    return yield unless folder

    previous = song
    self.song = folder
    begin
      yield
    ensure
      self.song = previous
    end
  end
end
