# frozen_string_literal: true

require "tty-prompt"

# Couleurs ANSI partagées entre les assistants interactifs — évite qu'un même bleu
# (#00b9ff, Phil) soit redéfini ailleurs sous une autre forme.
module AnsiColors
  BLUE = "\e[38;2;0;185;255m"
  SUCCESS = "\e[32m"
  # Rouge ANSI standard (`\e[31m`) trop sombre à l'usage (Phil) — vrai rouge clair
  # (RGB), même forme truecolor que `BLUE`.
  ERROR = "\e[38;2;255;90;90m"
  GRAY = "\e[90m"
  RESET = "\e[0m"

  def blue(text)
    "#{BLUE}#{text}#{RESET}"
  end

  def success(text)
    "#{SUCCESS}#{text}#{RESET}"
  end

  def error(text)
    "#{ERROR}#{text}#{RESET}"
  end

  def gray(text)
    "#{GRAY}#{text}#{RESET}"
  end

  # `TTY::Prompt.new` avec notre bleu comme couleur de l'item survolé (Phil, 2026-08-30
  # — défaut de la gem `active_color: :green`, trompeur : le vert est réservé aux
  # messages de résultat/succès dans cette appli, `success`). À utiliser PARTOUT à la
  # place de `TTY::Prompt.new` nu.
  def colored_prompt
    TTY::Prompt.new(active_color: ->(s) { blue(s) })
  end
end
