module AresMUSH

  class Bootstrapper 

    def self.client_monitor
      @@client_monitor
    end
    
    attr_reader :command_line
    
    def initialize
      config_reader = ConfigReader.new(Dir.pwd + "/game")
      config_reader.read
      port = config_reader.config['server']['port']

      @@client_monitor = AresMUSH::ClientMonitor.new(config_reader)
      @command_line = AresMUSH::CommandLine.new(config_reader)
    end
  end

end