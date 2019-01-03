require 'colorize'
require 'logger'

module Optx
  # Optanix Ruby Logger class
  class Logger < ::Logger
    def initialize(logdev, shift_age = 0, shift_size = 1_048_576)
      super

      @default_formatter = Optx::Logger::Formatter.new
      @formatter = @default_formatter
    end

    # Formatter that adds color and the script callback to log lines
    class Formatter < ::Logger::Formatter
      FORMAT = "%s, [%s#%d] %5s -- [%s:%d][%s][%s]\n".freeze

      # This method is invoked when a log event occurs
      def call(severity, time, _progname, msg)
        kaller = find_caller(caller)
        msg = format(FORMAT, severity[0..0], format_datetime(time), $$, severity,
                     kaller[0], kaller[1], kaller[2], msg2str(msg))
        _colorize(msg, severity)
      end

      # Finds the last method call before the logger class
      def find_caller(kaller)
        kaller.each do |line|
          next if line =~ /logger\.rb/

          # /Users/homans/code/devops/lib/optx/api.rb:38:in `get'
          file, number, meth = line.split(':')
          meth =~ /`([^']*)'/
          return [File.basename(file), number, Regexp.last_match(1).gsub(/(.+\sin\s)/, '')]
        end
      end

      private

      # @param msg [String]
      # @param severity [String]
      # @return [String]
      def _colorize(msg, severity)
        case severity
        when 'DEBUG'
          msg.colorize(:green)
        when 'INFO'
          msg.colorize(:cyan)
        when 'WARN'
          msg.colorize(:yellow)
        when 'ERROR'
          msg.colorize(:red)
        when 'FATAL'
          msg.colorize(background: :red)
        when 'UNKNOWN'
          msg
        else
          msg
        end
      end
    end
  end
end

