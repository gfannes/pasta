require('fileutils')

here_dir = File.dirname(__FILE__)
gubg_dir = ENV['gubg']
gubg_bin_dir = File.join(gubg_dir, 'bin')

task :default do
    sh 'rake -T'
end

desc 'Install'
task :install do
    mode = :safe
    # mode = :fast
    # mode = :debug

    m = {safe: :safe, fast: :fast}[mode]
    mode_str = m ? "--release=#{m}" : ''
    sh("zig build install #{mode_str} --prefix-exe-dir #{gubg_bin_dir}")
end

desc('Clean')
task :clean do
    FileUtils.rm_rf('target')
    FileUtils.rm_rf('zig-out')
end
