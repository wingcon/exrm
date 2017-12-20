defmodule ReleaseManager.Utils do
  @moduledoc """
  This module provides helper functions for the `mix release` and
  `mix release.clean` tasks.
  """
  import Mix.Shell,    only: [cmd: 2]
  alias ReleaseManager.Utils.Logger

  # Relx constants
  @relx_output_path      "rel"

  @doc """
  Perform some actions within the context of a specific mix environment
  """
  def with_env(env, fun) do
    old_env = Mix.env
    try do
      # Change env
      Mix.env(env)
      fun.()
    after
      # Change back
      Mix.env(old_env)
    end
  end

  @doc """
  Load the current project's configuration
  """
  def load_config(env, project_config \\ Mix.Project.config) do
    config_path = Keyword.get(project_config, :config_path, "config/config.exs")
    with_env env, fn ->
      if File.regular?(config_path) do
        Mix.Config.read! config_path
      else
        []
      end
    end
  end

  @doc """
  Call the _elixir mix binary with the given arguments
  """
  def mix(command, :quiet),        do: mix(command, :dev, :quiet)
  def mix(command, :verbose),      do: mix(command, :dev, :verbose)
  def mix(command, env),           do: mix(command, env, :quiet)
  def mix(command, env, :quiet) do
    case :os.type() do
      {:nt}            -> do_cmd("(set MIX_ENV=#{env}) & (mix #{command})", &ignore/1)
      {:win32, :nt}    -> do_cmd("(set MIX_ENV=#{env}) & (mix #{command})", &ignore/1)
      _                -> do_cmd("MIX_ENV=#{env} mix #{command}", &ignore/1)
    end
  end
  def mix(command, env, :verbose) do
    case :os.type() do
      {:nt}            -> do_cmd("(set MIX_ENV=#{env}) & (mix #{command})", &IO.write/1)
      {:win32, :nt}    -> do_cmd("(set MIX_ENV=#{env}) & (mix #{command})", &IO.write/1)
      _                -> do_cmd("MIX_ENV=#{env} mix #{command}", &IO.write/1)
    end
  end
  @doc """
  Change user permissions for a target file or directory
  """
  def chmod(target, mode) do
    case File.chmod(target, mode) do
      :ok         -> :ok
      {:error, _} -> :ok
    end
  end
  @doc """
  Execute `relx`
  """
  def relx(name, version, verbosity, upgrade?, dev_mode?) do
    # Setup paths
    config     = rel_file_dest_path "relx.config"
    output_dir = @relx_output_path |> Path.expand
    # Convert friendly verbosity names to relx values
    v = case verbosity do
      :silent  -> 0
      :quiet   -> 1
      :normal  -> 2
      :verbose -> 3
      _        -> 2 # Normal if we get an odd value
    end
    # Let relx do the heavy lifting
    relx_args = [
        log_level: v,
        root_dir: '#{File.cwd!}',
        config: '#{config}',
        relname: '#{name}',
        relvsn: '#{version}',
        output_dir: '#{output_dir}',
        dev_mode: dev_mode?
      ]
    result = cond do
      upgrade? && dev_mode? ->
        last_release = get_last_release(name)
        :relx.do [{:upfrom, '#{last_release}'} | relx_args], ['release', 'relup']
      upgrade? ->
        last_release = get_last_release(name)
        :relx.do [{:upfrom, '#{last_release}'} | relx_args], ['release', 'relup', 'tar']
      dev_mode? ->
        :relx.do relx_args, ['release']
      true ->
        :relx.do relx_args, ['release', 'tar']
    end
    case result do
      {:ok, _state} -> :ok
      {:error, e} ->
        case e do
          {:rlx_prv_release, :no_goals_specified} ->
            {:error, "No goals have been specified for this release!"}
          {:rlx_prv_release, {:release_erts_error, dir}} ->
            {:error, "ERTS could not be found in #{dir}"}
          {:rlx_prv_release, {:no_release_name, vsn}} ->
            {:error, "A target release version was specified (#{vsn}) but no name."}
          {:rlx_prv_release, {:invalid_release_info, info}} ->
            {:error, "Target release information is in an invalid format:\n#{inspect info}"}
          {:rlx_prv_release, {:multiple_release_names, a, b}} ->
            {:error, "Multiple releases are defined, but no default was specified: #{a}, #{b}"}
          {:rlx_prv_release, :no_releases_in_system} ->
            {:error, "No releases have been defined! See the debug output for more information."}
          {:rlx_prv_release, {:no_releases_for, name}} ->
            {:error, "No releases exist for #{name}. See the debug output for more information."}
          {:rlx_prv_release, {:release_not_found, {name, vsn}}} ->
            {:error, "No such release: #{name}-#{vsn}. See the debug output for more information."}
          {:rlx_prv_release, {:failed_solve, {:unreachable_package, missing_app}}} ->
            {:error, "Unable to find application #{missing_app}. See the debug output for more information."}
          {:rlx_prv_relup, {:relup_generation_error, current_name, upfrom_name}}->
            {:error, "Unknown internal release error generating the relup from #{upfrom_name} to #{current_name}. See debug output."}
          {:rlx_prv_relup, {:relup_generation_warning, module, warnings}}->
            {:error, "Warnings generating relup:\n#{:rlx_util.indent(2)}#{module.format_warning(warnings)}"}
          {:rlx_prv_relup, {:no_upfrom_release_found, :undefined}} ->
            {:error, "Could not find any previous versions of the release to upgrade!"}
          {:rlx_prv_relup, {:no_upfrom_release_found, vsn}} ->
            {:error, "Could not find find release version #{vsn} for relup!"}
          {:rlx_prv_relup, {:relup_script_generation_error, {:relup_script_generator_error, :systools_relup, {:missing_sasl, _}}}} ->
            {:error, "Unfortunately, due to requirements in systools, you need to have the sasl application \n  in both current release and the release to upgrade from."}
          {:rlx_prv_relup, {:relup_script_generation_error, module, errors}}->
            {:error, "Failed to generate relup: #{:rlx_util.indent(2)}#{module.format_error(errors)}"}
          {:rlx_prv_archive, {:tar_unknown_generation_error, module, vsn}}->
            {:error, "Unknown error occurred when generating tarball for #{module}-#{vsn}\n  Do you have any file names longer than 100 characters? That is a known issue with systools."}
          {:rlx_prv_archive, {:tar_generation_warn, module, warnings}}->
            {:error, "Warnings were reported when generating the release tarball:\n#{:rlx_util.indent(2)}#{module}: #{inspect warnings}"}
          {:rlx_prv_archive, {:tar_generation_error, module, errors}}->
            {:error, "Errors occurred when generating the release tarball:\n#{:rlx_util.indent(2)}#{module}: #{inspect errors}"}
          {:rlx_app_info, {:vsn_parse, app}}->
            {:error, "Could not parse version for #{app}"}
          {_relx_module, _unhandled_err} ->
            {:error, "Failed to build release. See the debug output for specifics."}
        end
    end
  end

  @doc "Exits with exit status 1"
  def abort!, do: exit({:shutdown, 1})

  @doc """
  Get a list of tuples representing the previous releases:

  ## Examples

      get_releases #=> [{"test", "0.0.1"}, {"test", "0.0.2"}]

  """
  def get_releases(project) do
    release_path = Path.join([File.cwd!, "rel", project, "releases"])
    case release_path |> File.exists? do
      false -> []
      true  ->
        release_path
        |> File.ls!
        |> Enum.reject(fn entry -> entry in ["RELEASES", "start_erl.data"] end)
        |> Enum.map(fn version -> {project, version} end)
    end
  end

  @doc """
  Get the most recent release prior to the current one
  """
  def get_last_release(project) do
    hd(project |> get_releases |> Enum.map(fn {_, v} -> v end) |> sort_versions)
  end

  @doc """
  Sort a list of versions, latest one first. Tries to use semver version
  compare, but can fall back to regular string compare.
  """
  def sort_versions(versions) do
    versions
    |> Enum.map(fn ver ->
        # Special handling for git-describe versions
        compared = case Regex.named_captures(~r/(?<ver>\d+\.\d+\.\d+)-(?<commits>\d+)-(?<sha>[A-Ga-g0-9]+)/, ver) do
          nil ->
            {:standard, ver, nil}
          %{"ver" => version, "commits" => n, "sha" => sha} ->
            {:describe, <<version::binary, ?+, n::binary, ?-, sha::binary>>, String.to_integer(n)}
        end
        {ver, compared}
      end)
    |> Enum.sort(
      fn {_, {v1type, v1str, v1_commits_since}}, {_, {v2type, v2str, v2_commits_since}} ->
        case { parse_version(v1str), parse_version(v2str) } do
          {{:semantic, v1}, {:semantic, v2}} ->
            case Version.compare(v1, v2) do
              :gt -> true
              :eq ->
                case {v1type, v2type} do
                  {:standard, :standard} -> v1 > v2 # probably always false
                  {:standard, :describe} -> false   # v2 is an incremental version over v1
                  {:describe, :standard} -> true    # v1 is an incremental version over v2
                  {:describe, :describe} ->         # need to parse out the bits
                    v1_commits_since > v2_commits_since
                end
              :lt -> false
            end;
          {{_, v1}, {_, v2}} ->
            v1 >  v2
        end
      end)
    |> Enum.map(fn {v, _} -> v end)
  end

  defp parse_version(ver) do
    case Version.parse(ver) do
      {:ok, semver} -> {:semantic, semver}
      :error        -> {:nonsemantic, ver}
    end
  end

  @doc """
  Get the local paths of the current Elixir libraries
  """
  def get_elixir_lib_paths() do
    [elixir_lib_path, _] = String.split("#{:code.which(:elixir)}", "/elixir/ebin/elixir.beam")
    elixir_lib_path
    |> Path.expand
    |> File.ls!
    |> Enum.map(&(Path.join(elixir_lib_path, &1 <> "/ebin")))
  end

  @doc """
  Writes an Elixir/Erlang term to the provided path
  """
  def write_term(path, term) do
    :file.write_file('#{path}', :io_lib.fwrite('~p.\n', [term]))
  end

  @doc """
  Writes a collection of Elixir/Erlang terms to the provided path
  """
  def write_terms(path, terms) when is_list(terms) do
    format_str = String.duplicate("~p.\n\n", Enum.count(terms)) |> String.to_charlist
    :file.write_file('#{path}', :io_lib.fwrite(format_str, terms |> Enum.reverse), [encoding: :utf8])
  end

  @doc """
  Reads a file as Erlang terms
  """
  def read_terms(path) do
    result = case '#{path}' |> :file.consult do
      {:ok, terms} ->
        terms
      {:error, {line, type, msg}} ->
        Logger.error "Unable to parse #{path}: Line #{line}, #{type}, - #{msg}"
        abort!()
      {:error, reason} ->
        Logger.error "Unable to access #{path}: #{reason}"
        abort!()
    end
    result
  end

  @doc """
  Convert a string to Erlang terms
  """
  def string_to_terms(str) do
    str
    |> String.split("}.")
    |> Stream.map(&(String.trim(&1, ?\n)))
    |> Stream.map(&String.trim/1)
    |> Stream.map(&('#{&1}}.'))
    |> Stream.map(&(:erl_scan.string(&1)))
    |> Stream.map(fn {:ok, tokens, _} -> :erl_parse.parse_term(tokens) end)
    |> Stream.filter(fn {:ok, _} -> true; {:error, _} -> false end)
    |> Enum.reduce([], fn {:ok, term}, acc -> [term|acc] end)
    |> Enum.reverse
  end

  @doc """
  Merges two sets of Elixir/Erlang terms, where the terms come
  in the form of lists of tuples. For example, such as is found
  in the relx.config file
  """
  def merge(old, new) when is_list(old) and is_list(new) do
    merge(old, new, [])
  end

  defp merge([h|t], new, acc) when is_tuple(h) do
    case :lists.keytake(elem(h, 0), 1, new) do
      {:value, new_value, rest} ->
        # Value is present in new, so merge the value
        merged = merge_term(h, new_value)
        merge(t, rest, [merged|acc])
      false ->
        # Value doesn't exist in new, so add it
        merge(t, new, [h|acc])
    end
  end
  defp merge([], new, acc) do
    Enum.reverse(acc, new)
  end

  defp merge_term(old, new) when is_tuple(old) and is_tuple(new) do
    old
    |> Tuple.to_list
    |> Enum.with_index
    |> Enum.reduce([], fn
        {[], idx}, acc ->
          [elem(new, idx)|acc]
        {val, idx}, acc when is_list(val) ->
          case :io_lib.char_list(val) do
            true ->
              [elem(new, idx)|acc]
            false ->
              merged = val |> Enum.concat(elem(new, idx)) |> Enum.uniq
              [merged|acc]
          end
        {val, idx}, acc when is_tuple(val) ->
          [merge_term(val, elem(new, idx))|acc]
        {_val, idx}, acc ->
          [elem(new, idx)|acc]
       end)
    |> Enum.reverse
    |> List.to_tuple
  end

  @doc "Get the priv path of the exrm dependency"
  def priv_path, do: "#{:code.priv_dir('exrm')}"
  @doc "Get the priv/rel path of the exrm dependency"
  def rel_source_path,       do: Path.join(priv_path(), "rel")
  @doc "Get the path to a file located in priv/rel of the exrm dependency"
  def rel_source_path(file), do: Path.join(rel_source_path(), file)
  @doc "Get the priv/rel/files path of the exrm dependency"
  def rel_file_source_path,       do: Path.join([priv_path(), "rel", "files"])
  @doc "Get the path to a file located in priv/rel/files of the exrm dependency"
  def rel_file_source_path(file), do: Path.join(rel_file_source_path(), file)
  @doc """
  Get the path to a file located in the rel directory of the current project.
  You can pass either a file name, or a list of directories to a file, like:

      iex> ReleaseManager.Utils.rel_dest_path "relx.config"
      "path/to/project/rel/relx.config"

      iex> ReleaseManager.Utils.rel_dest_path ["<project>", "lib", "<project>.appup"]
      "path/to/project/rel/<project>/lib/<project>.appup"

  """
  def rel_dest_path(files) when is_list(files), do: Path.join([rel_dest_path()] ++ files)
  def rel_dest_path(file),                      do: Path.join(rel_dest_path(), file)
  @doc "Get the rel path of the current project."
  def rel_dest_path,                            do: Path.join(File.cwd!, "rel")
  @doc """
  Get the path to a file located in the rel/.files directory of the current project.
  You can pass either a file name, or a list of directories to a file, like:

      iex> ReleaseManager.Utils.rel_file_dest_path "sys.config"
      "path/to/project/rel/.files/sys.config"

      iex> ReleaseManager.Utils.rel_dest_path ["some", "path", "file.txt"]
      "path/to/project/rel/.files/some/path/file.txt"

  """
  def rel_file_dest_path(files) when is_list(files), do: Path.join([rel_file_dest_path()] ++ files)
  def rel_file_dest_path(file),                      do: Path.join(rel_file_dest_path(), file)
  @doc "Get the rel/.files path of the current project."
  def rel_file_dest_path,                            do: Path.join([File.cwd!, "rel", ".files"])

  # Ignore a message when used as the callback for Mix.Shell.cmd
  defp ignore(_), do: nil

  defp do_cmd(command, callback) do
    case cmd(command, callback) do
      0 -> :ok
      _ -> {:error, "Release step failed. Please fix any errors and try again."}
    end
  end

end
