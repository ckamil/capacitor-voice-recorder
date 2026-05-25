package com.tchvu3.capacitorvoicerecorder;

public class RecordOptions {

    private String directory;
    private String subDirectory;
    private StreamingConfig streaming;

    public RecordOptions(String directory, String subDirectory) {
        this.directory = directory;
        this.subDirectory = subDirectory;
    }

    public StreamingConfig getStreaming() {
        return streaming;
    }

    public void setStreaming(StreamingConfig streaming) {
        this.streaming = streaming;
    }

    public String getDirectory() {
        return directory;
    }

    public String getSubDirectory() {
        return subDirectory;
    }

    public void setSubDirectory(String subDirectory) {
        this.subDirectory = subDirectory;
    }
}
