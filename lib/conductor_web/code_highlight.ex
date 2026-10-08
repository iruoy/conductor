defmodule ConductorWeb.CodeHighlight do
  @moduledoc "Server-rendered syntax highlighting for tool code, with a literal fallback."

  @lexers %{
    ".ex" => Makeup.Lexers.ElixirLexer,
    ".exs" => Makeup.Lexers.ElixirLexer,
    ".erl" => Makeup.Lexers.ErlangLexer,
    ".hrl" => Makeup.Lexers.ErlangLexer,
    ".html" => Makeup.Lexers.HTMLLexer,
    ".htm" => Makeup.Lexers.HTMLLexer,
    ".heex" => Makeup.Lexers.HEExLexer,
    ".eex" => Makeup.Lexers.EExLexer,
    ".json" => Makeup.Lexers.JsonLexer
  }

  def render(source, path) when is_binary(source) do
    extension = if is_binary(path), do: Path.extname(path), else: ""

    lexer =
      case Map.fetch(@lexers, extension) do
        {:ok, lexer} -> {lexer, []}
        :error -> Makeup.Registry.get_lexer_by_extension(String.trim_leading(extension, "."))
      end

    highlight(source, lexer)
  end

  def diff(source) when is_binary(source) do
    highlight(source, {Makeup.Lexers.DiffLexer, []})
  end

  defp highlight(source, nil), do: Phoenix.HTML.html_escape(source)

  defp highlight(source, {lexer, options}) do
    source
    |> Makeup.highlight_inner_html(lexer: lexer, lexer_options: options)
    |> Phoenix.HTML.raw()
  rescue
    # Partial or unsupported source must never prevent a tool result from rendering.
    _error -> Phoenix.HTML.html_escape(source)
  end
end
