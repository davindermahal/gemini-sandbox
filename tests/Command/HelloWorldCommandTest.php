<?php

namespace App\Tests\Command;

use App\Command\HelloWorldCommand;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Console\Application;
use Symfony\Component\Console\Tester\CommandTester;

class HelloWorldCommandTest extends TestCase
{
    public function testPrintsHelloWorld(): void
    {
        $application = new Application();
        $application->addCommand(new HelloWorldCommand());

        $tester = new CommandTester($application->find('app:hello'));
        $tester->execute([]);

        $tester->assertCommandIsSuccessful();
        $this->assertStringContainsString('Hello world', $tester->getDisplay());
    }
}
