﻿module dcv.io.video;


/**
 * Module for video I/O
 * 
 * Wraps the ffmpeg library to perform video streaming.
 * 
 * TODO: Document!
 */

private import std.stdio : writeln;
private import std.exception : enforce;

private import ffmpeg.libavcodec.avcodec;
private import ffmpeg.libavformat.avformat;
private import ffmpeg.libavutil.avutil;
private import ffmpeg.libswscale.swscale;
private import ffmpeg.libavdevice.avdevice;
private import ffmpeg.libavfilter.avfilter;

public import dcv.io.image;

enum VideoStreamType : int {
	INVALID = 0,
	INPUT = 0x00100,
	OUTPUT = 0x00200,
	FILE = 0x00010,
	LIVE = 0x00020,
}

/**
 * Video streaming utility.
 * 
 * Perform FILE/output video streaming. Wraps FFmpeg library.
 */
class VideoStream {
private:
	AVFormatContext *formatContext = null;
	AVCodecContext *codecContext = null;
	AVStream *stream = null;
	VideoStreamType type = VideoStreamType.INVALID;

public:
	this() {
		AVStarter AV_STARTER_INSTANCE = AVStarter.instance();
	}

	~this() {
		close();
	}

	//! Check if stream is open.
	@property isOpen() const {
		return formatContext !is null;
	}

	/**
	 * Check type of the stream.
	 */
	@property isInputStream() const {
		return (type & VideoStreamType.INPUT) == VideoStreamType.INPUT;
	}
	//! ditto
	@property isOutputStream() const {
		return (type & VideoStreamType.OUTPUT) == VideoStreamType.OUTPUT;
	}
	//! ditto
	@property isFileStream() const {
		return (type & VideoStreamType.FILE) == VideoStreamType.FILE;
	}
	//! ditto
	@property isLiveStream() const {
		return (type & VideoStreamType.LIVE) == VideoStreamType.LIVE;
	}

	/**
	 * Open the video stream.
	 * 
	 * params:
	 * path = Path to the stream. 
	 * type = Stream type. 
	 */
	bool open(in string path, VideoStreamType type = (VideoStreamType.INPUT | VideoStreamType.FILE)) { 
		this.type = type;
		if (isInputStream) {
			if (isFileStream) {
				return openInputStreamImpl(null, path);
			} else if (isLiveStream) {
				version(Windows) {
					AVInputFormat *fmt = av_find_input_format("dshow");
					if (fmt is null) {
						fmt = av_find_input_format("vfwcap");
					}
				} else version(linux) {
					AVInputFormat *fmt = av_find_input_format("v4l2");
				} else version (OSX) {
					AVInputFormat *fmt = av_find_input_format("avfoundation");
				} else {
					static assert(0, "Not supported platform");
				}
				
				if (fmt is null) {
					throw new Exception("Cannot find correspoding FILE format for the platform"); 
				}
				return openInputStreamImpl(fmt, path);
			} else {
				throw new Exception("Invalid video type input.");
			}
		} else {
			throw new Exception("Output Stream Yet Not Implemented");
		}
	}

	void close() {
		if (formatContext) {
			avformat_close_input(&formatContext);
			formatContext = null;
		}
	}

	bool seekFrame(size_t frame) {
		enforce(isFileStream && isInputStream, "Only input file streams can be seeked.");

		if (stream is null)
			throw new Exception("Stream is not open");
		if (codecContext is null)
			throw new Exception("Codec context is invalid.");
		enforce(frame < frameCount, "Invalid frame");

		double frameDuration = 1. / frameRate;
		double seekSeconds = frame*frameDuration;
		int seekTarget = cast(int)(seekSeconds*(stream.time_base.den))/(stream.time_base.num);

		if(av_seek_frame(formatContext, cast(int)streamIndex, seekTarget, AVSEEK_FLAG_ANY) < 0) {
			writeln("Seeking frame ", frame, " failed.");
			return false;
		}

		return true;
	}
	
	bool seekTime(double seekSeconds) {
		enforce(isFileStream && isInputStream, "Only input file streams can be seeked.");

		if (stream is null)
			throw new Exception("Stream is not open");
		if (codecContext is null)
			throw new Exception("Codec context is invalid.");

		int seekTarget = cast(int)(seekSeconds*(stream.time_base.den))/(stream.time_base.num);

		if(av_seek_frame(formatContext, cast(int)streamIndex, seekTarget, AVSEEK_FLAG_ANY) < 0) {
			writeln("Seeking time ", seekSeconds, "s failed.");
			return false;
		}

		return true;
	}

	bool readFrame(ref Image image) {
		if (isInputStream) {
			return readFrameImpl(image);
		} else {
			throw new Exception("Not an input stream");
		}
	}

	bool writeFrame(Image image) {
		enforce(isOutputStream, "Stream is not output, cannot write frame");
		throw new Exception("Not implemented");
	}

	@property size_t width() const {
		if (stream is null)
			throw new Exception("Stream is not open");
		return stream.codec.width;
	}

	@property size_t height() const {
		if (stream is null)
			throw new Exception("Stream is not open");
		return stream.codec.height;
	}

	@property size_t frameSize() const {
		return avpicture_get_size(pixelFormat, cast(int)width, cast(int)height);
	}

	@property size_t frameCount() const {
		if (stream is null)
			throw new Exception("Stream is not open");
		return stream.nb_frames;
	}

	@property size_t streamIndex() const {
		if (stream is null)
			throw new Exception("Stream is not open");
		return stream.index;
	}

	@property float frameRate() const {
		if (stream is null)
			throw new Exception("Stream is not open");
		return stream.r_frame_rate.num / cast(float)stream.r_frame_rate.den;
	}

	void dumpFormat() const {
		if (formatContext)
			av_dump_format(cast(AVFormatContext*)formatContext, 0, "", 0);
		else
			writeln("Cannot dump format: format invalid (stream is not opened)");
	}

private:
		
	bool readFrameImpl(ref Image image) {
		bool stat = false;

		AVPacket packet;
		av_init_packet(&packet);

		// allocating an AVFrame
		AVFrame *frame = av_frame_alloc();
		
		if (!frame) {
			writeln("Could not allocate frame\n");
			return false;
		}

		scope(exit) {
			av_frame_free(&frame);
			av_free_packet(&packet);
		}

		while (av_read_frame(formatContext, &packet) >= 0) {
			int ret = 0;
			int gotFrame = 0;
			if (packet.stream_index == streamIndex) {
				ret = avcodec_decode_video2(codecContext, frame, &gotFrame, &packet);
				if (ret < 0) {
					// TODO: collect and error as a code: ret;
					writeln("Error decoding video frame.");
					return false;
				}

				if (gotFrame) {
					stat = true;

					if (image is null || image.byteSize != frameSize) {
						image = new Image(width, height, AVPixelFormat_to_ImageFormat(pixelFormat), BitDepth.BD_8);
					}

					adoptFormat(pixelFormat, frame, image.data);

					break;
				}
			}
		}
		return stat;
	}

	bool openInputStreamImpl(AVInputFormat *inputFormat, in string filepath) {
		const char *file = cast(const char *)filepath.dup.ptr;
		int streamIndex = -1;

		// open FILE file, and allocate format context
		if (avformat_open_input(&formatContext, filepath.ptr, inputFormat, null) < 0) {
			writeln("Could not open stream for file: ", filepath);
			return false;
		}

		// retrieve stream information 
		if (avformat_find_stream_info(formatContext, null) < 0) {
			writeln("Could not find stream information");
			return false;
		}

		if (openCodecContext(&streamIndex, formatContext, AVMediaType.AVMEDIA_TYPE_VIDEO)	>= 0) {
			stream = formatContext.streams[streamIndex];
			codecContext = stream.codec;
		}
		
		if (!stream) {
			writeln("Could not find video stream in the FILE, aborting");
			return false;
		}

		debug {
			av_dump_format(formatContext, 0, file, 0);
		}
		
		//////////////////////////////////////////////////////////////////////////

		return true;
	}

	AVPixelFormat convertDepricatedPixelFormat(AVPixelFormat pix) const {
		AVPixelFormat pixFormat = pix;
		switch (pix) {
			case AVPixelFormat.AV_PIX_FMT_YUVJ420P :
				pixFormat = AVPixelFormat.AV_PIX_FMT_YUV420P;
				break;
			case AVPixelFormat.AV_PIX_FMT_YUVJ422P  :
				pixFormat = AVPixelFormat.AV_PIX_FMT_YUV422P;
				break;
			case AVPixelFormat.AV_PIX_FMT_YUVJ444P   :
				pixFormat = AVPixelFormat.AV_PIX_FMT_YUV444P;
				break;
			case AVPixelFormat.AV_PIX_FMT_YUVJ440P :
				pixFormat = AVPixelFormat.AV_PIX_FMT_YUV440P;
				break;
			default:
				break;
		}
		return pixFormat;
	}

	
	int openCodecContext(int *stream_idx, AVFormatContext *fmt_ctx, AVMediaType type) {
		int ret;

		AVStream *st;
		AVCodecContext *dec_ctx = null;
		AVCodec *dec = null;
		AVDictionary *opts = null;

		ret = av_find_best_stream(fmt_ctx, type, -1, -1, null, 0);
		if (ret < 0) {
			writeln("Could not find stream in FILE file.");
			return ret;
		} else {
			*stream_idx = ret;
			st = fmt_ctx.streams[*stream_idx];
			/* find decoder for the stream */
			dec_ctx = st.codec;
			dec = avcodec_find_decoder(dec_ctx.codec_id);

			if (!dec) {
				writeln("Failed to find codec: ", av_get_media_type_string(type));
				return -1;
			}

			if ((ret = avcodec_open2(dec_ctx, dec, &opts)) < 0) {
				writeln("Failed to open codec: ",
					av_get_media_type_string(type));
				return ret;
			}
		}

		return 0;
	}

	@property AVPixelFormat pixelFormat() const {
		if (stream is null)
			throw new Exception("Stream is not open");
		return convertDepricatedPixelFormat(stream.codec.pix_fmt);
	}


}

private:

class AVStarter {
	private static AVStarter _instance = null;
	static AVStarter instance() { 
		if (AVStarter._instance is null)
			AVStarter._instance = new AVStarter;
		return AVStarter._instance;
	}
	this() {
		av_register_all();
		avformat_network_init();
		avcodec_register_all();
		avfilter_register_all();
		avdevice_register_all();
	}
}

immutable IF_MONO_TYPES = [	
	AVPixelFormat.AV_PIX_FMT_GRAY8
];

immutable IF_MONO_ALPHA_TYPES = [
	AVPixelFormat.AV_PIX_FMT_GRAY8A
];

immutable IF_YUV_TYPES = [
	AVPixelFormat.AV_PIX_FMT_YUV410P,
	AVPixelFormat.AV_PIX_FMT_YUV411P,
	AVPixelFormat.AV_PIX_FMT_YUV420P,
	AVPixelFormat.AV_PIX_FMT_YUV422P,
	AVPixelFormat.AV_PIX_FMT_YUYV422,
	AVPixelFormat.AV_PIX_FMT_YUV440P,
	AVPixelFormat.AV_PIX_FMT_YUV444P
];

immutable IF_RGB_TYPES = [
	AVPixelFormat.AV_PIX_FMT_RGB0,
	AVPixelFormat.AV_PIX_FMT_RGB24,
	AVPixelFormat.AV_PIX_FMT_RGB4,
	AVPixelFormat.AV_PIX_FMT_RGB8
];

immutable IF_RGB_ALPHA_TYPES = [
	AVPixelFormat.AV_PIX_FMT_ARGB,
	AVPixelFormat.AV_PIX_FMT_RGBA
];

immutable IF_BGR_TYPES = [
	AVPixelFormat.AV_PIX_FMT_BGR0,
	AVPixelFormat.AV_PIX_FMT_BGR24,
	AVPixelFormat.AV_PIX_FMT_BGR4,
	AVPixelFormat.AV_PIX_FMT_BGR8
];

immutable IF_BGR_ALPHA_TYPES = [
	AVPixelFormat.AV_PIX_FMT_ABGR,
	AVPixelFormat.AV_PIX_FMT_BGRA
];

alias IF_MONO_PREFERED = AVPixelFormat.AV_PIX_FMT_GRAY8;
alias IF_MONO_ALPHA_PREFERED = AVPixelFormat.AV_PIX_FMT_GRAY8A;
alias IF_RGB_PREFERED = AVPixelFormat.AV_PIX_FMT_RGB24;
alias IF_RGB_ALPHA_PREFERED = AVPixelFormat.AV_PIX_FMT_RGBA;
alias IF_BGR_PREFERED = AVPixelFormat.AV_PIX_FMT_BGR24;
alias IF_BGR_ALPHA_PREFERED = AVPixelFormat.AV_PIX_FMT_BGRA;
alias IF_YUV_PREFERED = AVPixelFormat.AV_PIX_FMT_YUV444P;

ImageFormat AVPixelFormat_to_ImageFormat(AVPixelFormat format) {
	import std.exception : enforce;
	import std.algorithm.searching : find;

	if (IF_YUV_TYPES.find(format)) {
		return ImageFormat.IF_YUV;
	} else if (IF_RGB_TYPES.find(format)) {
		return ImageFormat.IF_RGB;
	} else if (IF_BGR_TYPES.find(format)) {
		return ImageFormat.IF_BGR;
	} else if (IF_RGB_ALPHA_TYPES.find(format)) {
		return ImageFormat.IF_RGB_ALPHA;
	} else if (IF_BGR_ALPHA_TYPES.find(format)) {
		return ImageFormat.IF_BGR_ALPHA;
	} else if (IF_MONO_TYPES.find(format)) {
		return ImageFormat.IF_MONO;
	} else if (IF_MONO_ALPHA_TYPES.find(format)) {
		return ImageFormat.IF_MONO_ALPHA;
	} else {
		enforce(0, "Format type is not supported");
	}
	return ImageFormat.IF_UNASSIGNED;
}

void adoptFormat(AVPixelFormat format, AVFrame *frame, ubyte [] data) {

	import std.exception : enforce;
	import std.algorithm.searching : find;

	if (IF_YUV_TYPES.find(format)) {
		adoptYUV(format, frame, data);
	} else if (IF_RGB_TYPES.find(format)) {
		throw new Exception("Not implemented");
	} else if (IF_BGR_TYPES.find(format)) {
		throw new Exception("Not implemented");
	} else if (IF_RGB_ALPHA_TYPES.find(format)) {
		throw new Exception("Not implemented");
	} else if (IF_BGR_ALPHA_TYPES.find(format)) {
		throw new Exception("Not implemented");
	} else if (IF_MONO_TYPES.find(format)) {
		throw new Exception("Not implemented");
	} else if (IF_MONO_ALPHA_TYPES.find(format)) {
		throw new Exception("Not implemented");
	} else {
		enforce(0, "Format type is not supported");
	}
}

void adoptYUV(AVPixelFormat format, AVFrame *frame, ubyte []data) {
	switch (format) {
		case AVPixelFormat.AV_PIX_FMT_YUV410P,
			AVPixelFormat.AV_PIX_FMT_YUV420P,
			AVPixelFormat.AV_PIX_FMT_YUV440P:
				adoptYUVGrouped(frame, data);
		break;
		case AVPixelFormat.AV_PIX_FMT_YUV411P:
			adoptYUV411P(frame, data);
			break;
		case AVPixelFormat.AV_PIX_FMT_YUV422P:
			adoptYUV422P(frame, data);
			break;
		case AVPixelFormat.AV_PIX_FMT_YUYV422:
			adoptYUYV422(frame, data);
			break;
		case AVPixelFormat.AV_PIX_FMT_YUV444P:
			adoptYUV444P(frame, data);
			break;
		default:
			assert(0);
	}
}

void adoptYUVGrouped(AVFrame *frame, ubyte []data) {
	auto ysize = frame.linesize[0];
	auto usize = frame.linesize[1];
	auto vsize = frame.linesize[2];

	auto udiv = ysize / usize;
	auto vdiv = ysize / vsize;

	int w = frame.width;
	int h = frame.height;

	if (data.length != w*h*3)
		data.length = w*h*3;

	auto ydata = frame.data[0];
	auto udata = frame.data[1];
	auto vdata = frame.data[2];

	foreach(r; 0..h) {
		foreach(c; 0..w) {
			auto pixpos = r*w*3 + c*3;
			auto ypos = r*w + c;
			auto uvpos = r/2 * w / 2 + c / 2;			
			data[pixpos + 0] = ydata[ypos];
			data[pixpos + 1] = udata[uvpos];
			data[pixpos + 2] = vdata[uvpos];
		}
	}
}

void adoptYUV411P(AVFrame *frame, ubyte []data) {

	int w = frame.width;
	int h = frame.height;
	int s = (w*h) / 4;

	auto ydata = frame.data[0];
	auto udata = frame.data[1];
	auto vdata = frame.data[2];

	foreach(i; 0..s) {
		auto y1 = ydata[i*4];
		auto y2 = ydata[i*4+1];
		auto y3 = ydata[i*4+2];
		auto y4 = ydata[i*4+3];
		auto u = udata[i];
		auto v = vdata[i];

		data[i*12 + 0] = y1;
		data[i*12 + 1] = u;
		data[i*12 + 2] = v;

		data[i*12 + 3] = y2;
		data[i*12 + 4] = u;
		data[i*12 + 5] = v;

		data[i*12 + 3] = y3;
		data[i*12 + 4] = u;
		data[i*12 + 5] = v;

		data[i*12 + 3] = y4;
		data[i*12 + 4] = u;
		data[i*12 + 5] = v;
	}
}

void adoptYUV422P(AVFrame *frame, ubyte []data) {

	int w = frame.width;
	int h = frame.height;
	int s = (w*h) / 2;

	auto ydata = frame.data[0];
	auto udata = frame.data[1];
	auto vdata = frame.data[2];

	foreach(i; 0..s) {
		auto y1 = ydata[i*2];
		auto y2 = ydata[i*2+1];
		auto u = udata[i];
		auto v = vdata[i];

		data[i*6 + 0] = y1;
		data[i*6 + 1] = u;
		data[i*6 + 2] = v;

		data[i*6 + 3] = y2;
		data[i*6 + 4] = u;
		data[i*6 + 5] = v;
	}
}

void adoptYUYV422(AVFrame *frame, ubyte []data) {

	int w = frame.width;
	int h = frame.height;
	int s = (w*h) / 2;

	auto yuyvdata = frame.data[0];

	ulong dataIter = 0;
	ulong yuyvIter = 0;

	foreach(i; 0..s) {
		auto y1 = yuyvdata[yuyvIter++];
		auto u = yuyvdata[yuyvIter++];
		auto y2 = yuyvdata[yuyvIter++];
		auto v = yuyvdata[yuyvIter++];

		data[dataIter++] = y1;
		data[dataIter++] = u;
		data[dataIter++] = v;

		data[dataIter++] = y2;
		data[dataIter++] = u;
		data[dataIter++] = v;
	}
}

void adoptYUV444P(AVFrame *frame, ubyte []data) {
	foreach(i; 0..frame.width*frame.height) {
		data[i*3 + 0] = frame.data[0][i];
		data[i*3 + 1] = frame.data[1][i];
		data[i*3 + 2] = frame.data[2][i];
	}
}
