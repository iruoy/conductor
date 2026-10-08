defmodule ConductorWeb.AnsiOutput do
  @moduledoc """
  Renders untrusted terminal output as escaped text and generated inline spans.

  Supports SGR foreground/background colors (16, 256 and RGB), bold, faint,
  italic, underline, inverse and strikethrough, including their selective resets.
  Other terminal controls, OSC links and incomplete escape sequences are discarded.
  This is not a terminal emulator: cursor movement and carriage returns are ignored.
  Spaces, tabs and newlines are preserved by the enclosing output `pre`.

  Only ESC/CSI-prefixed codes are interpreted; literal `[31m` remains text.
  No input is trusted as HTML, an attribute, a URL, a CSS value or an atom.
  """

  # Conventional terminal palette, also used by the first 16 xterm colors.
  @palette {
    "#000000",
    "#800000",
    "#008000",
    "#808000",
    "#000080",
    "#800080",
    "#008080",
    "#c0c0c0",
    "#808080",
    "#ff0000",
    "#00ff00",
    "#ffff00",
    "#0000ff",
    "#ff00ff",
    "#00ffff",
    "#ffffff"
  }

  @spec render(String.t() | nil) :: {:safe, iodata()}
  def render(nil), do: {:safe, []}

  def render(text) when is_binary(text) do
    {:safe, scan(text, %{}, [], [])}
  end

  defp scan(<<>>, style, text, html), do: html |> flush(text, style) |> Enum.reverse()

  defp scan(<<27, "[", rest::binary>>, style, text, html),
    do: csi(rest, style, text, html)

  defp scan(<<27, control, rest::binary>>, style, text, html)
       when control in [?], ?P, ?X, ?^, ?_] do
    scan(strip_string(rest, control == ?]), style, text, html)
  end

  defp scan(<<27, rest::binary>>, style, text, html),
    do: scan(strip_escape(rest), style, text, html)

  # Accept both UTF-8 C1 controls and their single-byte terminal form.
  defp scan(<<0xC2, 0x9B, rest::binary>>, style, text, html),
    do: csi(rest, style, text, html)

  defp scan(<<0x9B, rest::binary>>, style, text, html),
    do: csi(rest, style, text, html)

  defp scan(<<0xC2, control, rest::binary>>, style, text, html)
       when control in [0x90, 0x98, 0x9D, 0x9E, 0x9F] do
    scan(strip_string(rest, control == 0x9D), style, text, html)
  end

  defp scan(<<control, rest::binary>>, style, text, html)
       when control in [0x90, 0x98, 0x9D, 0x9E, 0x9F] do
    scan(strip_string(rest, control == 0x9D), style, text, html)
  end

  defp scan(<<control, rest::binary>>, style, text, html)
       when control < 32 and control not in [9, 10] do
    scan(rest, style, text, html)
  end

  defp scan(<<char::utf8, rest::binary>>, style, text, html)
       when char in 127..159 do
    scan(rest, style, text, html)
  end

  defp scan(<<char::utf8, rest::binary>>, style, text, html),
    do: scan(rest, style, [<<char::utf8>> | text], html)

  defp scan(<<control, rest::binary>>, style, text, html) when control in 128..159,
    do: scan(rest, style, text, html)

  # Tool output is byte-truncated upstream; an incomplete UTF-8 character must
  # not prevent the rest of an output snapshot from rendering.
  defp scan(<<_invalid, rest::binary>>, style, text, html),
    do: scan(drop_continuations(rest), style, ["�" | text], html)

  # A continuation byte of a cut UTF-8 character is not a standalone C1 control.
  defp drop_continuations(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_continuations(rest)

  defp drop_continuations(rest), do: rest

  defp csi(input, style, text, html) do
    case take_csi(input, 0) do
      {parameters, ?m, rest} ->
        next_style = sgr(parameters, style)

        if next_style == style do
          scan(rest, style, text, html)
        else
          scan(rest, next_style, [], flush(html, text, style))
        end

      {_parameters, _unsupported, rest} ->
        scan(rest, style, text, html)
    end
  end

  defp take_csi(input, offset) when offset == byte_size(input), do: {"", nil, ""}

  defp take_csi(input, offset) do
    case :binary.at(input, offset) do
      final when final in 0x40..0x7E ->
        parameters = binary_part(input, 0, offset)
        rest = binary_part(input, offset + 1, byte_size(input) - offset - 1)
        {parameters, final, rest}

      part when part in 0x20..0x3F ->
        take_csi(input, offset + 1)

      _invalid ->
        # Discard an incomplete fragment, not the following newline/truncation
        # marker or the next escape sequence in a streaming snapshot.
        {"", nil, binary_part(input, offset, byte_size(input) - offset)}
    end
  end

  defp strip_escape(<<part, rest::binary>>) when part in 0x20..0x2F,
    do: strip_escape(rest)

  defp strip_escape(<<final, rest::binary>>) when final in 0x30..0x7E, do: rest
  defp strip_escape(rest), do: rest

  defp strip_string(<<>>, _osc?), do: ""
  defp strip_string(<<7, rest::binary>>, true), do: rest
  defp strip_string(<<27, "\\", rest::binary>>, _osc?), do: rest
  defp strip_string(<<0xC2, 0x9C, rest::binary>>, _osc?), do: rest
  defp strip_string(<<0x9C, rest::binary>>, _osc?), do: rest

  # Skip whole characters so a UTF-8 continuation byte cannot be mistaken for
  # the single-byte ST control inside an OSC URL or other terminal payload.
  defp strip_string(<<_char::utf8, rest::binary>>, osc?), do: strip_string(rest, osc?)
  defp strip_string(<<_byte, rest::binary>>, osc?), do: strip_string(rest, osc?)

  # SGR accepts numbers only. Bound each parameter before parsing, and bound the
  # whole code so hostile huge integers cannot cause work or become CSS values.
  defp sgr(parameters, style) when byte_size(parameters) <= 256 do
    if Regex.match?(~r/\A[0-9;]*\z/, parameters) do
      parameters |> String.split(";") |> Enum.map(&parameter/1) |> apply_sgr(style)
    else
      style
    end
  end

  defp sgr(_parameters, style), do: style

  defp parameter(""), do: 0
  defp parameter(value) when byte_size(value) <= 3, do: String.to_integer(value)
  defp parameter(_value), do: :unsupported

  defp apply_sgr([], style), do: style

  defp apply_sgr([code, 2, r, g, b | rest], style) when code in [38, 48] do
    style =
      if channel?(r) and channel?(g) and channel?(b),
        do: Map.put(style, color_key(code), "rgb(#{r}, #{g}, #{b})"),
        else: style

    apply_sgr(rest, style)
  end

  defp apply_sgr([code, 5, color | rest], style) when code in [38, 48] do
    style =
      if channel?(color),
        do: Map.put(style, color_key(code), indexed_color(color)),
        else: style

    apply_sgr(rest, style)
  end

  # A malformed extended color is atomic; its remaining values must not be
  # reinterpreted as emphasis/reset codes.
  defp apply_sgr([code | _rest], style) when code in [38, 48], do: style

  defp apply_sgr([code | rest], style), do: apply_sgr(rest, apply_code(code, style))

  defp channel?(value), do: is_integer(value) and value in 0..255
  defp color_key(38), do: :foreground
  defp color_key(48), do: :background

  defp indexed_color(color) when color < 16, do: elem(@palette, color)

  defp indexed_color(color) when color >= 232 do
    level = 8 + (color - 232) * 10
    "rgb(#{level}, #{level}, #{level})"
  end

  defp indexed_color(color) do
    index = color - 16
    r = cube_level(div(index, 36))
    g = cube_level(rem(div(index, 6), 6))
    b = cube_level(rem(index, 6))
    "rgb(#{r}, #{g}, #{b})"
  end

  defp cube_level(0), do: 0
  defp cube_level(level), do: 55 + level * 40

  defp apply_code(0, _style), do: %{}
  defp apply_code(1, style), do: Map.put(style, :bold, true)
  defp apply_code(2, style), do: Map.put(style, :faint, true)
  defp apply_code(3, style), do: Map.put(style, :italic, true)
  defp apply_code(4, style), do: Map.put(style, :underline, true)
  defp apply_code(7, style), do: Map.put(style, :inverse, true)
  defp apply_code(9, style), do: Map.put(style, :strike, true)
  defp apply_code(22, style), do: Map.drop(style, [:bold, :faint])
  defp apply_code(23, style), do: Map.delete(style, :italic)
  defp apply_code(24, style), do: Map.delete(style, :underline)
  defp apply_code(27, style), do: Map.delete(style, :inverse)
  defp apply_code(29, style), do: Map.delete(style, :strike)
  defp apply_code(39, style), do: Map.delete(style, :foreground)
  defp apply_code(49, style), do: Map.delete(style, :background)

  defp apply_code(code, style) when code in 30..37,
    do: Map.put(style, :foreground, elem(@palette, code - 30))

  defp apply_code(code, style) when code in 40..47,
    do: Map.put(style, :background, elem(@palette, code - 40))

  defp apply_code(code, style) when code in 90..97,
    do: Map.put(style, :foreground, elem(@palette, code - 90 + 8))

  defp apply_code(code, style) when code in 100..107,
    do: Map.put(style, :background, elem(@palette, code - 100 + 8))

  defp apply_code(_unsupported, style), do: style

  defp flush(html, [], _style), do: html

  defp flush(html, text, style) do
    escaped = text |> Enum.reverse() |> IO.iodata_to_binary() |> Phoenix.HTML.Safe.to_iodata()

    case css(style) do
      [] -> [escaped | html]
      declarations -> [["<span style=\"", declarations, "\">", escaped, "</span>"] | html]
    end
  end

  # These are the only trusted markup/style strings. Colors come exclusively
  # from the fixed palette or validated integers, never arbitrary input.
  defp css(style) do
    {foreground, background} =
      if style[:inverse] do
        {style[:background] || "var(--surface-2)", style[:foreground] || "var(--fg-pre)"}
      else
        {style[:foreground], style[:background]}
      end

    decoration =
      [style[:underline] && "underline", style[:strike] && "line-through"]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    [
      foreground && ["color:", foreground, ";"],
      background && ["background-color:", background, ";"],
      style[:bold] && "font-weight:600;",
      style[:faint] && "opacity:0.5;",
      style[:italic] && "font-style:italic;",
      decoration != "" && ["text-decoration:", decoration, ";"]
    ]
    |> Enum.filter(& &1)
  end
end
