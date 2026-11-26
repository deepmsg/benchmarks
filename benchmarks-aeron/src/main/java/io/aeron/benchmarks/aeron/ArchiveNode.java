/*
 * Copyright 2015-2025 Real Logic Limited.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.aeron.benchmarks.aeron;

import io.aeron.Aeron;
import io.aeron.ExclusivePublication;
import io.aeron.Subscription;
import io.aeron.archive.client.AeronArchive;
import io.aeron.benchmarks.Configuration;
import org.agrona.concurrent.ShutdownSignalBarrier;
import org.agrona.concurrent.SystemNanoClock;

import java.io.File;
import java.nio.file.Path;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;

import static io.aeron.ChannelUri.addSessionId;
import static io.aeron.archive.client.AeronArchive.connect;
import static io.aeron.archive.codecs.SourceLocation.LOCAL;
import static io.aeron.benchmarks.PropertiesUtil.loadPropertiesFiles;
import static io.aeron.benchmarks.PropertiesUtil.mergeWithSystemProperties;
import static io.aeron.benchmarks.aeron.AeronUtil.awaitConnected;
import static io.aeron.benchmarks.aeron.AeronUtil.awaitRecordingStart;
import static io.aeron.benchmarks.aeron.AeronUtil.connectionTimeoutNs;
import static io.aeron.benchmarks.aeron.AeronUtil.destinationChannel;
import static io.aeron.benchmarks.aeron.AeronUtil.destinationStreamId;
import static io.aeron.benchmarks.aeron.AeronUtil.launchArchivingMediaDriver;
import static io.aeron.benchmarks.aeron.AeronUtil.pipeMessages;
import static io.aeron.benchmarks.aeron.AeronUtil.recordChannel;
import static io.aeron.benchmarks.aeron.AeronUtil.recordStream;
import static org.agrona.CloseHelper.closeAll;
import static org.agrona.PropertyAction.PRESERVE;
import static org.agrona.PropertyAction.REPLACE;

/**
 * Remote node which archives received messages and replays persisted messages back to the sender.
 * Counterpart for the {@link LiveReplayMessageTransceiver}.
 */
public final class ArchiveNode implements AutoCloseable, Runnable
{
    /**
     * When true this node connects to an archive somebody else runs instead of launching one of
     * its own; the archive is reached through {@code aeron.archive.control.channel} exactly as a
     * client reaches it. The measurement side -- the forwarding and the answer that is the
     * archive's replay rather than the node's -- is untouched, which is the point: a cell may
     * swap the archive and nothing else.
     */
    public static final String ARCHIVE_EXTERNAL_PROP_NAME = "io.aeron.benchmarks.aeron.archive.external";

    /** Where an external archive keeps its recordings, for the error dump at the end. */
    private static final String ARCHIVE_DIR_PROP_NAME = "aeron.archive.dir";

    private final AtomicBoolean running;
    private final ArchivingMediaDriver archivingMediaDriver;
    private final AeronArchive aeronArchive;
    private final boolean ownsArchiveClient;
    private final ExclusivePublication publication;
    private final Subscription subscription;

    ArchiveNode(final AtomicBoolean running)
    {
        this(running, externalArchive() ? null : launchArchivingMediaDriver(), connect(), true);
    }

    private static boolean externalArchive()
    {
        return Boolean.getBoolean(ARCHIVE_EXTERNAL_PROP_NAME);
    }

    ArchiveNode(
        final AtomicBoolean running,
        final ArchivingMediaDriver archivingMediaDriver,
        final AeronArchive aeronArchive,
        final boolean ownsArchiveClient)
    {
        this.running = running;
        this.archivingMediaDriver = archivingMediaDriver;
        this.aeronArchive = aeronArchive;
        this.ownsArchiveClient = ownsArchiveClient;

        final Aeron aeron = aeronArchive.context().aeron();

        subscription = aeron.addSubscription(destinationChannel(), destinationStreamId());

        final String recordChannel = recordChannel();
        final int recordStreamId = recordStream();
        publication = aeron.addExclusivePublication(recordChannel, recordStreamId);

        final int publicationSessionId = publication.sessionId();
        final String channel = addSessionId(recordChannel, publicationSessionId);
        aeronArchive.startRecording(channel, recordStreamId, LOCAL, true);
    }

    public void run()
    {
        awaitConnected(
            () -> subscription.isConnected() && publication.availableWindow() > 0,
            connectionTimeoutNs(),
            SystemNanoClock.INSTANCE);

        awaitRecordingStart(aeronArchive.context().aeron(), publication.sessionId(), aeronArchive.archiveId());

        pipeMessages(subscription, publication, running);
    }

    public void close()
    {
        closeAll(publication, subscription);

        if (ownsArchiveClient)
        {
            if (null == archivingMediaDriver)
            {
                closeAll(aeronArchive);
            }
            else
            {
                closeAll(aeronArchive, archivingMediaDriver);
            }
        }
    }

    public static void main(final String[] args)
    {
        mergeWithSystemProperties(PRESERVE, loadPropertiesFiles(new Properties(), REPLACE, args));
        final Path outputDir = Configuration.resolveLogsDir();

        final AtomicBoolean running = new AtomicBoolean(true);
        try (ShutdownSignalBarrier shutdownSignalBarrier = new ShutdownSignalBarrier(() -> running.set(false));
            ArchiveNode server = new ArchiveNode(running))
        {
            // wait for all background threads to be started before pinning the main thread to a dedicated core
            Thread.currentThread().setName("archive-node");

            server.run();

            final String prefix = "archive-node-";
            // The same three dumps whichever archive this node talked to, taken from the driver it
            // is a client of rather than from an `ArchivingMediaDriver` this process may not own.
            final String aeronDirectoryName = server.aeronArchive.context().aeron()
                .context().aeronDirectoryName();
            final File archiveDir = null == server.archivingMediaDriver
                ? new File(System.getProperty(ARCHIVE_DIR_PROP_NAME, aeronDirectoryName))
                : server.archivingMediaDriver.archive.context().archiveDir();

            AeronUtil.dumpArchiveErrors(archiveDir, outputDir.resolve(prefix + "archive-errors.txt"));
            AeronUtil.dumpAeronStats(
                server.aeronArchive.context().aeron().context().cncFile(),
                outputDir.resolve(prefix + "aeron-stat.txt"),
                outputDir.resolve(prefix + "errors.txt")
            );
            AeronUtil.dumpLossStat(
                aeronDirectoryName,
                outputDir.resolve(prefix + "loss-stat.txt")
            );
        }
    }
}
