# coding: utf-8

require 'active_support'
require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/core_ext/hash/except'
require 'fog'
require 'tempfile'
require 'db2fog/railtie'

class DB2Fog
  cattr_accessor :config

  def full_backup
    file_name = "dump-#{db_credentials[:database]}-#{Time.now.utc.strftime("%Y%m%d%H%M")}.sql.gz"
    store.store(file_name, open(database.dump))
    store.store(most_recent_dump_file_name, file_name)
  end

  def restore
    dump_file_name = store.fetch(most_recent_dump_file_name).read
    file = store.fetch(dump_file_name)
    database.restore(file.path)
  end

  def clean
    to_keep = []
    filelist = store.list
    files = filelist.reject {|file| file.ends_with?(most_recent_dump_file_name) }.collect do |file|
      {
        :path => file,
        :date => Time.parse(file.split('-').last.split('.').first)
      }
    end
    # Keep all backups from the past day
    files.select {|x| x[:date] >= 1.day.ago }.each do |backup_for_day|
      to_keep << backup_for_day
    end

    # Keep one backup per day from the last week
    files.select {|x| x[:date] >= 1.week.ago }.group_by {|x| x[:date].strftime("%Y%m%d") }.values.each do |backups_for_last_week|
      to_keep << backups_for_last_week.sort_by{|x| x[:date].strftime("%Y%m%d") }.first
    end

    # Keep one backup per week since forever
    files.group_by {|x| x[:date].strftime("%Y%W") }.values.each do |backups_for_week|
      to_keep << backups_for_week.sort_by{|x| x[:date].strftime("%Y%m%d") }.first
    end

    to_destroy = filelist - to_keep.uniq.collect {|x| x[:path] }
    to_destroy.delete_if {|x| x.ends_with?(most_recent_dump_file_name) }
    to_destroy.each do |file|
      store.delete(file.split('/').last)
    end
  end

  private

  def store
    @store ||= FogStore.new
  end

  def most_recent_dump_file_name
    "most-recent-dump-#{db_credentials[:database]}.txt"
  end

  def db_credentials
    ActiveRecord::Base.connection.instance_eval { @config } # Dodgy!
  end

  def database
    @database ||= case db_credentials[:adapter]
                  when /mysql/    then MysqlAdaptor.new(db_credentials)
                  when /postgres/ then PsqlAdaptor.new(db_credentials)
                  else
                    raise "database adaptor '#{db_credentials[:adapter]}' not supported"
                  end
  end

  class MysqlAdaptor

    def initialize(credentials)
      @credentials = credentials
    end

    def dump
      dump_file = Tempfile.new("dump")

      cmd = "mysqldump --quick --single-transaction --create-options #{mysql_options}"
      cmd += " | gzip -9 > #{dump_file.path}"
      run(cmd)

      dump_file.path
    end

    def restore(path)
      run "gunzip -c #{path} | mysql #{mysql_options}"
    end

    private

    def mysql_options
      cmd = ''
      cmd += " -u #{@credentials[:username]} " unless @credentials[:username].nil?
      cmd += " -p'#{@credentials[:password]}'" unless @credentials[:password].nil?
      cmd += " -h '#{@credentials[:host]}'"    unless @credentials[:host].nil?
      cmd += " --default-character-set=#{@credentials[:encoding]}" unless @credentials[:encoding].nil?
      cmd += " #{@credentials[:database]}"
    end

    def run(command)
      result = system(command)
      raise("error, process exited with status #{$?.exitstatus}") unless result
    end

  end

  class PsqlAdaptor

    def initialize(credentials)
      @credentials = credentials
    end

    def dump
      dump_file = Tempfile.new("dump")

      cmd = "pg_dump --clean --format=p #{pg_dump_options}"
      cmd += " | gzip -9 > #{dump_file.path}"
      run(cmd)

      dump_file.path
    end

    def restore(path)
      run "gunzip -c #{path} | psql #{psql_options}"
    end

    private

    def pg_dump_options
      cmd = ''
      cmd += " -U #{@credentials[:username]} " unless @credentials[:username].nil?
      cmd += " -w"
      cmd += " -h '#{@credentials[:host]}'"    unless @credentials[:host].nil?
      cmd += " #{@credentials[:database]}"
    end

    def psql_options
      cmd = ''
      cmd += " -U #{@credentials[:username]} " unless @credentials[:username].nil?
      cmd += " -w"
      cmd += " -h '#{@credentials[:host]}'"    unless @credentials[:host].nil?
      cmd += " -d #{@credentials[:database]}"
    end

    def run(command)
      result = system(command)
      raise("error, process exited with status #{$?.exitstatus}") unless result
    end

  end

  class FogStore

    def store(remote_filename, io)
      directory.files.create(:key => remote_filename, :body => io, :public => false)
    end

    def fetch(remote_filename)
      remote_file = directory.files.get(remote_filename)

      file = Tempfile.new("dump")
      open(file.path, 'wb') { |f| f.write(remote_file.body) }
      file
    end

    def list
      directory.files.map { |f| f.key }
    end

    def delete(remote_filename)
      remote_file = directory.files.head(remote_filename)
      remote_file.destroy if remote_file
    end

    private

    def fog_options
      if DB2Fog.config.respond_to?(:[])
        DB2Fog.config.except(:directory)
      else
        raise "DB2Fog not configured"
      end
    end

    def directory_name
      if DB2Fog.config.respond_to?(:[])
      DB2Fog.config[:directory]
      else
        raise "DB2Fog not configured"
      end
    end

    def directory
      @directory ||= storage.directories.get(directory_name)
    end

    def storage
      @storage = Fog::Storage.new(fog_options)
    end
  end

end
