#-*-Mode:elixir;coding:utf-8;tab-width:2;c-basic-offset:2;indent-tabs-mode:()-*-
# ex: set ft=elixir fenc=utf-8 sts=2 ts=2 sw=2 et nomod:

defmodule CloudIServiceQuorum do
  use Mix.Project

  def project do
    [app: :cloudi_service_quorum,
     version: "1.7.3",
     language: :erlang,
     description: description(),
     package: package(),
     deps: deps()]
  end

  defp deps do
    [{:proper, "~> 1.2.0"},
     {:cloudi_core, "~> 1.7.3"}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework Quorum Service"
  end

  defp package do
    [files: ~w(src doc test rebar.config README.markdown),
     maintainers: ["Michael Truog"],
     licenses: ["MIT"],
     links: %{"Website" => "https://cloudi.org",
              "GitHub" => "https://github.com/CloudI/" <>
                          "cloudi_service_quorum"}]
   end
end
