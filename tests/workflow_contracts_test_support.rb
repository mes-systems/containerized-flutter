require "base64"

module WorkflowContractTestSupport
  def write_executable(path, contents)
    File.write(path, contents)
    File.chmod(0o755, path)
    path
  end

  def install_curl_stub
    write_executable(File.join(@bin_directory, "curl"), <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      File.open(ENV.fetch("CURL_LOG"), "a") { |handle| handle.puts(JSON.generate(ARGV)) }
      print File.read(ENV.fetch("ATTESTATION_FILE"))
    RUBY
  end

  def install_docker_stub
    write_executable(File.join(@bin_directory, "docker"), <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      args = ARGV
      if ENV["DOCKER_LOG"]
        File.open(ENV.fetch("DOCKER_LOG"), "a") { |handle| handle.puts(JSON.generate(args)) }
      end
      case ENV.fetch("DOCKER_MODE")
      when "driver"
        puts ENV.fetch("DRIVER_INFO", "")
      when "publish"
        if args.first == "push"
          exit 0
        elsif args[0, 3] == ["buildx", "imagetools", "inspect"]
          case args.fetch(5)
          when "{{.Manifest.Digest}}"
            puts ENV.fetch("REGISTRY_DIGEST")
          when "{{json .Provenance.SLSA}}"
            print File.read(ENV.fetch("PROVENANCE_FILE"))
          when "{{json .SBOM.SPDX}}"
            print File.read(ENV.fetch("SBOM_FILE"))
          else
            warn "unexpected image-inspect query"
            exit 90
          end
        else
          warn "unexpected docker invocation: #{args.join(" ")}"
          exit 91
        end
      when "cleanup"
        state_path = ENV.fetch("DOCKER_STATE")
        images = File.read(state_path).lines.map(&:chomp)
        if args[0, 2] == ["image", "inspect"]
          exit images.include?(args.fetch(2)) ? 0 : 1
        elsif args[0, 2] == ["image", "rm"]
          image = args.fetch(3)
          exit 1 if image == ENV["DOCKER_FAIL_REMOVE"]
          images.delete(image)
          File.write(state_path, images.empty? ? "" : images.join("\n") + "\n")
        else
          warn "unexpected docker cleanup invocation: #{args.join(" ")}"
          exit 92
        end
      else
        warn "unexpected docker mode"
        exit 93
      end
    RUBY
  end

  def install_gh_stub
    write_executable(File.join(@bin_directory, "gh"), <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      args = ARGV
      input = nil
      if (index = args.index("--input")) && args[index + 1] == "-"
        raw = STDIN.read
        input = JSON.parse(raw) unless raw.empty?
      end
      File.open(ENV.fetch("GH_LOG"), "a") do |handle|
        handle.puts(JSON.generate({"args" => args, "input" => input}))
      end

      if args[0] == "api" && args.include?("graphql")
        query = input.fetch("query")
        if query.include?("createCommitOnBranch")
          puts JSON.generate({"data" => {"createCommitOnBranch" => {"commit" => {"oid" => ENV.fetch("COMMIT_OID")}}}})
        elsif query.include?("updateRefs")
          if ENV["GH_UPDATE_MODE"] == "reject"
            puts JSON.generate({"errors" => [{"message" => "ref update rejected"}]})
          else
            state_path = ENV.fetch("GH_STATE")
            state = File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
            state["updated"] = true
            File.write(state_path, JSON.generate(state))
            puts JSON.generate({"data" => {"updateRefs" => {"clientMutationId" => nil}}})
          end
        else
          warn "unexpected GraphQL operation"
          exit 80
        end
        exit 0
      end

      if args[0] == "api"
        endpoint = args.find { |argument| argument.start_with?("repos/") }.to_s
        if (match = endpoint.match(%r{/commits/([0-9a-f]{40})\z}))
          sha = match[1]
          verified = if sha == ENV.fetch("MAIN_SHA")
            ENV["GH_EXISTING_VERIFIED"] == "true"
          else
            ENV["GH_COMMIT_VERIFIED"] == "true"
          end
          puts JSON.generate({
            "sha" => sha,
            "commit" => {"verification" => {"verified" => verified}},
            "parents" => [{"sha" => ENV.fetch("MAIN_SHA")}],
          })
        elsif endpoint.include?("/git/ref/heads/")
          state_path = ENV.fetch("GH_STATE")
          state = File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
          sha = if state["updated"]
            ENV.fetch("COMMIT_OID")
          else
            ENV["CURRENT_REMOTE_OVERRIDE"] || ENV["CURRENT_REMOTE_SHA"] || ENV.fetch("MAIN_SHA")
          end
          puts sha
        elsif endpoint == "repos/#{ENV['GITHUB_REPOSITORY']}"
          puts ENV.fetch("GH_REPO_NODE_ID", "R_fixture")
        elsif endpoint.end_with?("/git/refs")
          puts "{}"
        else
          puts "{}"
        end
        exit 0
      end

      if args[0, 2] == ["pr", "list"]
        puts ENV.fetch("GH_PR_NUMBER", "")
      elsif args[0, 2] == ["issue", "list"]
        print ENV.fetch("GH_ISSUES_JSON", "[]")
      elsif %w[create edit comment close].include?(args[1]) && %w[pr issue].include?(args[0])
        puts "{}"
      else
        warn "unexpected GitHub CLI invocation: #{args.join(" ")}"
        exit 81
      end
    RUBY
  end

  def write_json(name, value)
    path = File.join(@temporary_directory, name)
    File.write(path, JSON.generate(value))
    path
  end

  def provenance_document(digest)
    {
      "buildDefinition" => {
        "buildType" => BUILD_TYPE,
        "resolvedDependencies" => [{"digest" => {"sha256" => digest}}],
        "internalParameters" => {"buildConfig" => {"llbDefinition" => ["synthetic"]}},
      },
      "runDetails" => {"metadata" => {"buildkit_completeness" => {"request" => true}}},
    }
  end

  def attestation_documents(digest)
    [
      {
        "PredicateType" => SLSA_TYPE,
        "Statement" => {
          "predicateType" => SLSA_TYPE,
          "predicate" => provenance_document(digest),
        },
      },
      {
        "PredicateType" => SPDX_TYPE,
        "Statement" => {
          "predicateType" => SPDX_TYPE,
          "predicate" => {"SPDXID" => "SPDXRef-DOCUMENT", "spdxVersion" => "SPDX-2.3"},
        },
      },
    ]
  end

  def run_ci_classification(step, event_name, event, fetch_status: nil, cwd: ROOT)
    event_path = File.join(@temporary_directory, "event-#{rand(1_000_000)}.json")
    output = File.join(@temporary_directory, "classification-#{rand(1_000_000)}.txt")
    File.write(event_path, JSON.generate(event))
    File.write(output, "")
    environment = {
      "GITHUB_EVENT_NAME" => event_name,
      "GITHUB_EVENT_PATH" => event_path,
      "GITHUB_OUTPUT" => output,
    }
    environment.merge!(git_fetch_environment(fetch_status)) unless fetch_status.nil?
    result, stderr, stdout = run_step(step, cwd: cwd, env: environment)
    {result: result, stdout: stdout, stderr: stderr, output: output}
  end

  def git_fetch_environment(status)
    directory = File.join(@temporary_directory, "git-stub-#{rand(1_000_000)}")
    FileUtils.mkdir_p(directory)
    real_git = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      .map { |entry| File.join(entry, "git") }
      .find { |candidate| File.executable?(candidate) }
    raise "git is required for workflow contract tests" unless real_git
    write_executable(File.join(directory, "git"), <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      if ARGV.first == "fetch"
        File.open(ENV.fetch("GIT_LOG"), "a") { |handle| handle.puts(JSON.generate(ARGV)) }
        exit Integer(ENV.fetch("GIT_FETCH_STATUS"))
      end
      exec ENV.fetch("REAL_GIT"), *ARGV
    RUBY
    {
      "PATH" => "#{directory}:#{@bin_directory}:#{ENV.fetch('PATH', '')}",
      "REAL_GIT" => real_git,
      "GIT_FETCH_STATUS" => status.to_s,
      "GIT_LOG" => File.join(@temporary_directory, "git-fetch-#{rand(1_000_000)}.jsonl"),
    }
  end

  def make_classification_repository(changed_path)
    directory = File.join(@temporary_directory, "classification-#{rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(directory, "scripts"))
    FileUtils.cp(File.join(ROOT, "scripts", "classify-changes.sh"), File.join(directory, "scripts"))
    git!(["init", "--initial-branch=main", directory])
    git!(["-C", directory, "config", "user.name", "Contract Test"])
    git!(["-C", directory, "config", "user.email", "contract-test@example.invalid"])
    File.write(File.join(directory, "README.md"), "fixture baseline\n")
    git!(["-C", directory, "add", "README.md", "scripts/classify-changes.sh"])
    git!(["-C", directory, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "baseline"])
    base_sha = git!(["-C", directory, "rev-parse", "HEAD"]).strip
    path = File.join(directory, changed_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "fixture change\n")
    git!(["-C", directory, "add", changed_path])
    git!(["-C", directory, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "change #{changed_path}"])
    head_sha = git!(["-C", directory, "rev-parse", "HEAD"]).strip
    {directory: directory, base_sha: base_sha, head_sha: head_sha}
  end
end

class WorkflowContractsTest
  include WorkflowContractTestSupport

  def test_watcher_fixture_materializes_main_when_source_checkout_is_detached
    fixture = File.join(@temporary_directory, "detached-watcher-source")
    source_remote = File.join(fixture, "source.git")
    source_checkout = File.join(fixture, "source")
    seed = File.join(fixture, "main.git")
    checkout = File.join(fixture, "repo")
    FileUtils.mkdir_p(fixture)
    git!(["init", "--bare", "--initial-branch=main", source_remote])
    git!([
      "--git-dir", source_remote, "fetch", "--quiet", "--no-tags", ROOT,
      "refs/remotes/origin/main:refs/heads/main",
    ])
    git!(["clone", "--shared", "--quiet", "--no-checkout", source_remote, source_checkout])
    git!(["-C", source_checkout, "checkout", "--quiet", "--detach", "refs/remotes/origin/main"])
    git!(["-C", source_checkout, "branch", "-D", "main"])
    assert_equal("HEAD", git!(["-C", source_checkout, "rev-parse", "--abbrev-ref", "HEAD"]).strip)
    main_branch = Open3.capture3("git", "-C", source_checkout, "show-ref", "--verify", "--quiet", "refs/heads/main").last
    assert_equal(1, main_branch.exitstatus, "source checkout must not have a local main branch")

    main_sha = materialize_watcher_main(source_checkout, seed, checkout)
    assert_equal(
      main_sha,
      git!(["-C", checkout, "rev-parse", "HEAD"]).strip,
      "isolated watcher checkout must start at the origin/main commit",
    )
  end

  def test_github_watcher_commit_is_verified_before_compare_and_swap_update
    ["flutter-release-watch", "base-image-watch"].each do |name|
      outcome = run_watcher_commit(name)
      assert_equal(0, outcome.fetch(:result).exitstatus, outcome.fetch(:result).stderr)
      calls = outcome.fetch(:calls)
      assert_no_pull_request_merge(calls)
      create_call = calls.find { |call| call.dig("input", "query").to_s.include?("createCommitOnBranch") }
      update_call = calls.find { |call| call.dig("input", "query").to_s.include?("updateRefs") }
      assert_not_nil(create_call)
      assert_not_nil(
        update_call,
        "status=#{outcome.fetch(:result).exitstatus} stdout=#{outcome.fetch(:result).stdout.inspect} " \
        "stderr=#{outcome.fetch(:result).stderr.inspect} calls=#{calls.map { |call| call.fetch('args') }.inspect}",
      )
      input = create_call.dig("input", "variables", "input")
      assert_equal(outcome.fetch(:main_sha), input.fetch("expectedHeadOid"))
      additions = input.dig("fileChanges", "additions")
      manifest_path = name == "flutter-release-watch" ? "supported_version.json" : "supported_bases.json"
      assert_equal([manifest_path, "README.md"], additions.map { |item| item.fetch("path") })
      additions.each do |item|
        expected = File.binread(File.join(outcome.fetch(:repo), item.fetch("path")))
        assert_equal(expected, Base64.strict_decode64(item.fetch("contents")))
      end

      update = update_call.dig("input", "variables", "input").fetch("refUpdates").first
      assert_equal("refs/heads/#{workflow(name).fetch('env').fetch('WATCHER_BRANCH')}", update.fetch("name"))
      assert_equal("0" * 40, update.fetch("beforeOid"))
      assert_equal(COMMIT_OID, update.fetch("afterOid"))
      assert_equal(true, update.fetch("force"))
      verified_index = calls.index { |call| call.fetch("args").any? { |arg| arg.include?("/commits/#{COMMIT_OID}") } }
      update_index = calls.index(update_call)
      assert_operator(verified_index, :<, update_index)
      assert(calls.any? { |call| call.fetch("args").include?("--method") && call.fetch("args").include?("DELETE") })
      assert_equal(outcome.fetch(:main_sha), outcome.fetch(:head_after))
      assert_equal("", outcome.fetch(:remote_refs))
      forbidden_git_calls = outcome.fetch(:git_calls).select do |arguments|
        %w[add commit push].include?(arguments.first) ||
          (arguments.first == "config" && %w[user.name user.email].include?(arguments[1]))
      end
      assert_equal([], forbidden_git_calls, "watcher must create signed commits through GitHub without local Git publication")
    end
  end

  def test_unverified_watcher_commit_never_updates_the_canonical_branch
    ["flutter-release-watch", "base-image-watch"].each do |name|
      outcome = run_watcher_commit(name, environment: {"GH_COMMIT_VERIFIED" => "false"})
      assert_not_equal(0, outcome.fetch(:result).exitstatus)
      assert_include(outcome.fetch(:result).stderr, "not verified")
      assert_nil(outcome.fetch(:calls).find { |call| call.dig("input", "query").to_s.include?("updateRefs") })
      assert(outcome.fetch(:calls).any? { |call| call.fetch("args").include?("DELETE") })
      assert_equal("", outcome.fetch(:remote_refs))
    end
  end

  def test_existing_verified_watcher_commit_is_reused_without_creating_another
    ["flutter-release-watch", "base-image-watch"].each do |name|
      outcome = run_watcher_commit(
        name, existing: true, environment: {"GH_EXISTING_VERIFIED" => "true"},
      )
      assert_equal(0, outcome.fetch(:result).exitstatus, outcome.fetch(:result).stderr)
      assert_nil(outcome.fetch(:calls).find { |call| call.dig("input", "query").to_s.include?("createCommitOnBranch") })
      assert_nil(outcome.fetch(:calls).find { |call| call.dig("input", "query").to_s.include?("updateRefs") })
      assert_equal(outcome.fetch(:main_sha), outcome.fetch(:head_after))
    end
  end

  def test_existing_watcher_branch_uses_its_observed_sha_as_the_update_precondition
    outcome = run_watcher_commit("base-image-watch", existing: true, environment: {"GH_EXISTING_VERIFIED" => "false"})
    assert_equal(0, outcome.fetch(:result).exitstatus, outcome.fetch(:result).stderr)
    update = outcome.fetch(:calls).find { |call| call.dig("input", "query").to_s.include?("updateRefs") }
    assert_not_nil(
      update,
      "status=#{outcome.fetch(:result).exitstatus} stdout=#{outcome.fetch(:result).stdout.inspect} " \
      "stderr=#{outcome.fetch(:result).stderr.inspect} " \
      "calls=#{outcome.fetch(:calls).map { |call| call.fetch('args') }.inspect}",
    )
    ref_update = update.dig("input", "variables", "input", "refUpdates").first
    assert_equal(outcome.fetch(:main_sha), ref_update.fetch("beforeOid"))
  end

  def test_watcher_ref_races_and_github_rejections_stop_before_branch_completion
    raced = run_watcher_commit(
      "flutter-release-watch",
      existing: true,
      environment: {"GH_EXISTING_VERIFIED" => "false", "CURRENT_REMOTE_OVERRIDE" => "d" * 40},
    )
    assert_not_equal(0, raced.fetch(:result).exitstatus)
    assert_include(raced.fetch(:result).stderr, "changed while preparing")
    assert_nil(raced.fetch(:calls).find { |call| call.dig("input", "query").to_s.include?("updateRefs") })

    rejected = run_watcher_commit(
      "base-image-watch", existing: true,
      environment: {"GH_EXISTING_VERIFIED" => "false", "GH_UPDATE_MODE" => "reject"},
    )
    assert_not_equal(0, rejected.fetch(:result).exitstatus)
    assert_include(rejected.fetch(:result).stderr, "guarded watcher branch update")
    assert(rejected.fetch(:calls).any? { |call| call.fetch("args").include?("DELETE") })
  end

  def test_watcher_pull_request_and_anomaly_steps_use_stubbed_github_responses
    ["flutter-release-watch", "base-image-watch"].each do |name|
      created = run_maintenance_step(name, "Create or update watcher pull request", {"GH_PR_NUMBER" => ""})
      assert_equal(0, created.fetch(:result).exitstatus, created.fetch(:result).stderr)
      assert(created.fetch(:calls).any? { |call| call.fetch("args")[0, 2] == ["pr", "create"] })
      assert_no_pull_request_merge(created.fetch(:calls))

      updated = run_maintenance_step(name, "Create or update watcher pull request", {"GH_PR_NUMBER" => "17"})
      assert_equal(0, updated.fetch(:result).exitstatus, updated.fetch(:result).stderr)
      assert(updated.fetch(:calls).any? { |call| call.fetch("args")[0, 2] == ["pr", "edit"] })
      assert_no_pull_request_merge(updated.fetch(:calls))

      anomaly_title = workflow(name).fetch("env").fetch("ANOMALY_TITLE")
      issue = run_maintenance_step(name, "Create or update deduplicated anomaly issue", {"GH_ISSUES_JSON" => "[]"})
      assert_equal(0, issue.fetch(:result).exitstatus, issue.fetch(:result).stderr)
      assert(issue.fetch(:calls).any? { |call| call.fetch("args")[0, 2] == ["issue", "create"] })
      assert_no_pull_request_merge(issue.fetch(:calls))
      existing_issue = JSON.generate([{"number" => 9, "title" => anomaly_title}])
      issue = run_maintenance_step(
        name, "Create or update deduplicated anomaly issue", {"GH_ISSUES_JSON" => existing_issue},
      )
      assert_equal(0, issue.fetch(:result).exitstatus, issue.fetch(:result).stderr)
      assert(issue.fetch(:calls).any? { |call| call.fetch("args")[0, 2] == ["issue", "edit"] })
      assert_no_pull_request_merge(issue.fetch(:calls))
    end

    reconcile = step_named(workflow("base-image-watch"), "watch", "Reconcile obsolete watcher pull request")
    result = run_maintenance_step(
      "base-image-watch", "Reconcile obsolete watcher pull request",
      {"GH_PR_NUMBER" => "22"},
      expressions: {"steps.update.outputs.status" => "security_anomaly"},
    )
    assert_equal(0, result.fetch(:result).exitstatus, result.fetch(:result).stderr)
    assert(result.fetch(:calls).any? { |call| call.fetch("args")[0, 2] == ["pr", "comment"] })
    assert(result.fetch(:calls).any? { |call| call.fetch("args")[0, 2] == ["pr", "close"] })
    assert_no_pull_request_merge(result.fetch(:calls))
    assert_include(reconcile.fetch("if"), "security_anomaly")
    assert_include(reconcile.fetch("if"), "unchanged")
  end

  def assert_no_pull_request_merge(calls)
    assert_nil(calls.find { |call| call.fetch("args")[0, 2] == ["pr", "merge"] })
  end

  private

  def materialize_watcher_main(source_repo, seed_repo, checkout)
    git!(["init", "--bare", seed_repo])
    source_sha = git!(["-C", source_repo, "rev-parse", "--verify", "refs/remotes/origin/main^{commit}"]).strip
    git!([
      "--git-dir", seed_repo, "fetch", "--quiet", "--no-tags", source_repo,
      "refs/remotes/origin/main:refs/heads/main",
    ])
    main_sha = git!(["--git-dir", seed_repo, "rev-parse", "--verify", "refs/heads/main^{commit}"]).strip
    assert_equal(source_sha, main_sha, "isolated checkout must use the source origin/main commit")
    git!(["clone", "--shared", "--single-branch", "--quiet", "--branch", "main", seed_repo, checkout])
    main_sha
  end

  def run_watcher_commit(name, existing: false, environment: {})
    omit("watcher workflow uses Bash 4+ lowercase parameter expansion") unless @supports_bash_case_conversion
    @watcher_counter += 1
    fixture = File.join(@temporary_directory, "watcher-#{@watcher_counter}")
    repo = File.join(fixture, "repo")
    seed = File.join(fixture, "main.git")
    remote = File.join(fixture, "remote.git")
    FileUtils.mkdir_p(fixture)
    git!(["init", "--bare", "--initial-branch=main", remote])
    main_sha = materialize_watcher_main(ROOT, seed, repo)
    git!(["-C", repo, "remote", "set-url", "origin", remote])
    branch = workflow(name).fetch("env").fetch("WATCHER_BRANCH")
    if existing
      git!(["-C", repo, "update-ref", "refs/remotes/origin/#{branch}", main_sha])
    else
      Open3.capture3("git", "-C", repo, "update-ref", "-d", "refs/remotes/origin/#{branch}")
    end
    hook = File.join(remote, "hooks", "pre-receive")
    write_executable(hook, "#!/bin/sh\nexit 1\n")
    head_before = git!(["-C", repo, "rev-parse", "HEAD"]).strip

    gh_log = File.join(fixture, "gh.jsonl")
    state_path = File.join(fixture, "github-state.json")
    base_env = {
      "WATCHER_BRANCH" => branch, "PR_TITLE" => workflow(name).fetch("env").fetch("PR_TITLE"),
      "GITHUB_REPOSITORY" => "mes-systems/containerized-flutter", "GITHUB_RUN_ID" => "42",
      "GITHUB_RUN_ATTEMPT" => "1", "GH_TOKEN" => "stub-token", "GH_LOG" => gh_log,
      "GH_STATE" => state_path, "MAIN_SHA" => main_sha, "CURRENT_REMOTE_SHA" => main_sha,
      "COMMIT_OID" => COMMIT_OID, "GH_EXISTING_VERIFIED" => "false", "GH_COMMIT_VERIFIED" => "true",
    }.merge(environment)
    git_directory = File.join(fixture, "git-bin")
    FileUtils.mkdir_p(git_directory)
    git_log = File.join(fixture, "git.jsonl")
    real_git = ENV.fetch("PATH").split(File::PATH_SEPARATOR)
      .map { |directory| File.join(directory, "git") }
      .find { |path| File.file?(path) && File.executable?(path) }
    raise "git executable not found in PATH" unless real_git
    write_executable(File.join(git_directory, "git"), <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      File.open(ENV.fetch("GIT_LOG"), "a") { |handle| handle.puts(JSON.generate(ARGV)) }
      exec(ENV.fetch("REAL_GIT"), *ARGV)
    RUBY
    base_env.merge!("GIT_LOG" => git_log, "REAL_GIT" => real_git)
    step = step_named(workflow(name), "watch", "Create and verify GitHub-signed watcher commit")
    status, stderr, stdout = run_step(step, cwd: repo, env: base_env, executable_directory: git_directory)
    calls = File.exist?(gh_log) ? File.readlines(gh_log, chomp: true).map { |line| JSON.parse(line) } : []
    git_calls = File.exist?(git_log) ? File.readlines(git_log, chomp: true).map { |line| JSON.parse(line) } : []
    head_after = git!(["-C", repo, "rev-parse", "HEAD"]).strip
    remote_refs = git!(["--git-dir", remote, "for-each-ref"]).strip
    {result: Struct.new(:exitstatus, :stdout, :stderr).new(status.exitstatus, stdout, stderr),
     calls: calls, main_sha: main_sha, head_before: head_before, head_after: head_after,
     remote_refs: remote_refs, git_calls: git_calls, repo: repo}
  end

  def run_maintenance_step(name, step_name, overrides = {}, expressions: {})
    directory = File.join(@temporary_directory, "maintenance-#{rand(1_000_000)}")
    FileUtils.mkdir_p(directory)
    summary = File.join(directory, "summary.md")
    File.write(summary, "synthetic summary\n")
    log = File.join(directory, "gh.jsonl")
    document = workflow(name)
    env = {
      "WATCHER_BRANCH" => document.fetch("env").fetch("WATCHER_BRANCH"),
      "PR_TITLE" => document.fetch("env").fetch("PR_TITLE"),
      "ANOMALY_TITLE" => document.fetch("env").fetch("ANOMALY_TITLE"),
      "SUMMARY_MARKDOWN" => summary, "GH_TOKEN" => "stub-token", "GH_LOG" => log,
    }.merge(overrides)
    step = step_named(document, "watch", step_name)
    status, stderr, stdout = run_step(step, cwd: directory, env: env, expressions: expressions)
    calls = File.exist?(log) ? File.readlines(log, chomp: true).map { |line| JSON.parse(line) } : []
    {result: Struct.new(:exitstatus, :stdout, :stderr).new(status.exitstatus, stdout, stderr), calls: calls}
  end

  def git!(arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments)
    assert_equal(0, status.exitstatus, "git #{arguments.join(' ')}: #{stderr}")
    stdout
  end
end

class WorkflowContractsTest
  include WorkflowContractTestSupport
end
